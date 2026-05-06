defmodule Gingko.Memory do
  @moduledoc """
  Application-facing memory facade for MCP tools and LiveView monitor reads.

  This module keeps Mnemosyne details behind a stable Gingko boundary:
  - MCP writes/reads call this facade
  - project monitor topic/snapshot helpers are centralized here
  - domain errors are normalized into stable maps
  """

  require Logger

  alias Gingko.Memory.GraphView
  alias Gingko.Memory.ProjectRegistry
  alias Gingko.Memory.Serializer
  alias Gingko.Projects
  alias Mnemosyne.Config
  alias Mnemosyne.Errors.Framework.NotFoundError
  alias Mnemosyne.Errors.Framework.RepoError
  alias Mnemosyne.Errors.Framework.SessionError

  @project_topic_prefix "project"
  @project_topic_suffix "memory"
  @projects_stats_topic "projects:stats"

  @doc """
  Builds runtime options for the embedded Mnemosyne supervisor.
  """
  def mnemosyne_supervisor_opts do
    app_config = Application.fetch_env!(:gingko, __MODULE__)

    [
      config: struct!(Config, Keyword.fetch!(app_config, :mnemosyne_config)),
      llm: Keyword.fetch!(app_config, :llm_adapter),
      embedding: Keyword.fetch!(app_config, :embedding_adapter),
      notifier: Keyword.get(app_config, :notifier, Gingko.Memory.Notifier)
    ]
  end

  @doc """
  Returns the project-scoped PubSub topic used by the session monitor.
  """
  def project_monitor_topic(project_id) when is_binary(project_id) do
    "#{@project_topic_prefix}:#{project_id}:#{@project_topic_suffix}"
  end

  @doc """
  Returns the PubSub topic used for debounced project-stats broadcasts.
  """
  def projects_stats_topic, do: @projects_stats_topic

  @doc """
  Subscribes the caller to project stats change broadcasts.
  """
  def subscribe_projects_stats do
    Phoenix.PubSub.subscribe(Gingko.PubSub, @projects_stats_topic)
  end

  @doc """
  Broadcasts that per-project stats changed to subscribers of the shared topic.
  """
  def broadcast_project_stats_changed(project_id) when is_binary(project_id) do
    Phoenix.PubSub.broadcast(
      Gingko.PubSub,
      @projects_stats_topic,
      {:project_stats_changed, project_id}
    )
  end

  @doc """
  Returns the current monitor snapshot for a project, backed by SQLite.

  Returns a map with a `degraded: false` marker on the happy path. If project
  metadata lookup raises `Ecto.NoResultsError` — either from `Projects.list_sessions/2`
  or from `compute_quality/1` via `root_memory_descriptor/1` — returns a
  zero-valued snapshot with `degraded: true` so callers can render a warning
  badge instead of misleading zeros.
  """
  def project_monitor_snapshot(project_id) when is_binary(project_id) do
    active_sessions =
      project_id
      |> Projects.list_sessions(status: "active")
      |> Enum.map(&session_to_monitor_entry/1)

    %{
      project_id: project_id,
      degraded: false,
      active_sessions: active_sessions,
      recent_events: [],
      quality: compute_quality(project_id),
      counters: %{
        active_sessions: length(active_sessions),
        recent_commits: 0,
        recent_recalls: 0
      }
    }
  rescue
    Ecto.NoResultsError ->
      Logger.warning(
        "project_monitor_snapshot/1 degraded for project_id=#{project_id}: project metadata missing"
      )

      %{
        project_id: project_id,
        degraded: true,
        active_sessions: [],
        recent_events: [],
        quality: default_quality(),
        counters: %{active_sessions: 0, recent_commits: 0, recent_recalls: 0}
      }
  end

  defp session_to_monitor_entry(%Projects.Session{} = session) do
    %{
      session_id: session.session_id,
      state: String.to_existing_atom(session.status),
      latest_activity_at: session.updated_at,
      summary: %{goal: session.goal, node_count: session.node_count}
    }
  end

  defp compute_quality(project_id) do
    project = root_memory_descriptor(project_id)
    graph = load_graph(project.repo_id)

    {total_nodes, total_edges, orphan_count, confidence_sum, semantic_count} =
      graph.nodes
      |> Map.values()
      |> Enum.reduce({0, 0, 0, 0.0, 0}, fn node, {n, links, orphans, conf_sum, sem_count} ->
        link_size = typed_link_count(node.links)
        is_orphan = if link_size == 0, do: 1, else: 0

        case node do
          %Mnemosyne.Graph.Node.Semantic{confidence: c} ->
            {n + 1, links + link_size, orphans + is_orphan, conf_sum + c, sem_count + 1}

          _ ->
            {n + 1, links + link_size, orphans + is_orphan, conf_sum, sem_count}
        end
      end)

    avg_confidence = if semantic_count > 0, do: confidence_sum / semantic_count, else: nil

    %{
      total_nodes: total_nodes,
      total_edges: div(total_edges, 2),
      orphan_count: orphan_count,
      avg_confidence: avg_confidence,
      last_decay_at: nil,
      last_consolidation_at: nil,
      last_validation_at: nil
    }
  end

  defp default_quality do
    %{
      total_nodes: 0,
      total_edges: 0,
      orphan_count: 0,
      avg_confidence: nil,
      last_decay_at: nil,
      last_consolidation_at: nil,
      last_validation_at: nil
    }
  end

  @doc """
  Returns a normalized graph view for the project monitor.
  """
  def monitor_graph(%{project_id: project_id, view: view} = attrs) when is_binary(project_id) do
    project = root_memory_descriptor(project_id)
    graph = load_graph(project.repo_id)

    graph_view =
      case view do
        :project ->
          GraphView.project_view(graph,
            layout_mode: Map.get(attrs, :layout_mode, :force)
          )

        :focused ->
          GraphView.focused_view(
            graph,
            Map.get(attrs, :node_id),
            Map.get(attrs, :expanded_node_ids, MapSet.new())
          )

        :session ->
          GraphView.session_view(
            graph,
            Map.get(attrs, :session_id),
            session_node_ids(project_id, Map.get(attrs, :session_id)),
            Map.get(attrs, :expanded_node_ids, MapSet.new())
          )

        :query ->
          GraphView.query_view(
            graph,
            Map.get(attrs, :touched_node_ids, []),
            Map.get(attrs, :expanded_node_ids, MapSet.new())
          )
      end

    Map.put(
      graph_view,
      :layout_mode,
      Map.get(attrs, :layout_mode, Map.get(graph_view, :layout_mode))
    )
  end

  def open_project(project_id) do
    with {:ok, _project} <- Projects.register_project(%{project_key: project_id}),
         memory <- root_memory_descriptor(project_id) do
      ensure_memory_storage_root!(memory)

      if memory.repo_id in Mnemosyne.list_repos() do
        {:ok, project_result(memory, true)}
      else
        open_repo_for_memory(project_id, memory)
      end
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, %{code: :project_registration_failed, message: inspect(changeset.errors)}}
    end
  end

  defp open_repo_for_memory(project_id, memory) do
    open_opts =
      [backend: backend_for_path(memory.dets_path)]
      |> maybe_put_project_config(project_id)

    case Mnemosyne.open_repo(memory.repo_id, open_opts) do
      {:ok, _pid} -> {:ok, project_result(memory, false)}
      {:error, %RepoError{reason: :already_open}} -> {:ok, project_result(memory, true)}
      {:error, error} -> normalize_error(error)
    end
  end

  @doc """
  Closes and reopens the project's Mnemosyne repo so that a freshly-built
  `%Mnemosyne.Config{}` (with current per-project overlays) takes effect.

  Active sessions on the repo will be force-closed. Callers should warn the
  user before invoking.
  """
  @spec reload_project_config(String.t()) ::
          {:ok, map()} | {:error, term()}
  def reload_project_config(project_id) when is_binary(project_id) do
    memory = root_memory_descriptor(project_id)
    _ = safe_close_repo(memory.repo_id)
    open_project(project_id)
  end

  defp safe_close_repo(repo_id) do
    if repo_id in Mnemosyne.list_repos() do
      Mnemosyne.close_repo(repo_id)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_put_project_config(opts, project_id) do
    case project_mnemosyne_config(project_id) do
      nil -> opts
      config -> Keyword.put(opts, :config, config)
    end
  end

  defp project_mnemosyne_config(project_id) do
    with %Mnemosyne.Config{} = base <- base_mnemosyne_config(),
         overlay <- Projects.get_extraction_overlay(project_id) do
      effective =
        Gingko.Projects.ExtractionOverlay.to_extraction_profile(
          overlay,
          base.extraction_profile
        )

      %{base | extraction_profile: effective}
    else
      _ -> nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp base_mnemosyne_config do
    app_config = Application.get_env(:gingko, __MODULE__, [])

    case Keyword.get(app_config, :mnemosyne_config) do
      nil -> nil
      raw when is_map(raw) -> struct!(Config, raw)
      %Config{} = config -> config
    end
  end

  @doc """
  Triggers an async maintenance operation on the project's graph.

  Operations run in the background via Mnemosyne's maintenance lane.
  Results are delivered through Notifier events.
  """
  def run_maintenance(%{project_id: project_id, operation: operation}) do
    project = root_memory_descriptor(project_id)
    opts = Gingko.Settings.maintenance_opts(Gingko.Settings.load())

    result =
      case operation do
        :consolidate ->
          Mnemosyne.consolidate_semantics(project.repo_id,
            threshold: Keyword.fetch!(opts, :consolidation_threshold)
          )

        :decay ->
          Mnemosyne.decay_nodes(project.repo_id,
            threshold: Keyword.fetch!(opts, :decay_threshold)
          )

        :validate ->
          Mnemosyne.validate_episodic(project.repo_id)
      end

    case result do
      :ok -> {:ok, %{project_id: project_id, operation: operation, status: :queued}}
      {:error, error} -> normalize_error(error)
    end
  end

  def list_open_projects do
    Mnemosyne.list_repos()
  end

  def list_projects do
    projects =
      Enum.map(Projects.list_projects(), fn project ->
        root_memory = Projects.get_root_memory!(project.project_key)

        Serializer.project(%{
          project_id: project.project_key,
          repo_id: root_memory.repo_id,
          custom_overlays?: Projects.custom_overlays?(project)
        })
      end)

    %{projects: projects}
  end

  @doc """
  Aggregates per-project stats for the /projects card grid.

  Composes `project_monitor_snapshot/1` for each registered project. Each
  per-project snapshot is self-consistent; stale-between-projects data is
  acceptable.
  """
  @spec list_projects_with_stats() :: %{projects: [map()]}
  def list_projects_with_stats do
    projects =
      Enum.map(Projects.list_projects(), fn project ->
        snapshot = project_monitor_snapshot(project.project_key)
        quality = snapshot.quality
        counters = snapshot.counters
        active = snapshot.active_sessions

        last_activity =
          active
          |> Enum.map(& &1.latest_activity_at)
          |> Enum.reject(&is_nil/1)
          |> case do
            [] -> project_last_activity_fallback(project.project_key)
            timestamps -> Enum.max(timestamps, DateTime)
          end

        %{
          project_id: project.project_key,
          display_name: project.display_name || project.project_key,
          total_nodes: quality.total_nodes,
          total_edges: quality.total_edges,
          orphan_count: quality.orphan_count,
          avg_confidence: quality.avg_confidence,
          active_sessions: counters.active_sessions,
          last_activity_at: last_activity
        }
      end)

    %{projects: projects}
  end

  defp project_last_activity_fallback(project_key) do
    case Projects.list_sessions(project_key, status: "finished") do
      [session | _] -> session.finished_at || session.started_at
      _ -> nil
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  @doc """
  Reopens all registered project repos after the Mnemosyne runtime boots.
  """
  def reopen_registered_projects do
    Enum.each(Projects.list_projects(), fn project ->
      case open_project(project.project_key) do
        {:ok, _result} ->
          :ok

        {:error, error} ->
          Logger.warning(
            "Failed to reopen project repo for #{project.project_key}: #{inspect(error)}"
          )
      end
    end)

    :ok
  end

  def start_session(%{project_id: project_id, goal: goal} = attrs) do
    project = root_memory_descriptor(project_id)

    Logger.debug(
      "Starting memory session for project_id=#{project_id} repo_id=#{project.repo_id}"
    )

    case Mnemosyne.start_session(goal, repo: project.repo_id) do
      {:ok, session_id} ->
        Logger.debug("Started memory session session_id=#{session_id} project_id=#{project_id}")
        persist_session_open(project_id, session_id, goal)

        {:ok,
         %{
           project_id: project_id,
           repo_id: project.repo_id,
           session_id: session_id,
           agent: Map.get(attrs, :agent),
           thread_id: Map.get(attrs, :thread_id),
           state: :collecting
         }}

      {:error, error} ->
        Logger.debug(
          "Failed to start memory session for project_id=#{project_id}: #{Exception.message(error)}"
        )

        normalize_error(error)
    end
  end

  def summarize_step(%{session_id: session_id, content: content} = attrs) do
    Gingko.Cost.Context.with(
      %{
        project_key: Map.get(attrs, :project_key),
        session_id: session_id,
        feature: :step_summarization
      },
      fn ->
        case Gingko.Memory.Summarizer.extract(content) do
          {:ok, %{observation: observation, action: action}} ->
            append_step(%{session_id: session_id, observation: observation, action: action})

          {:error, :empty_content} ->
            {:error, %{code: :invalid_params, message: "content cannot be empty"}}

          {:error, %{code: _} = error} ->
            {:error, error}

          {:error, reason} ->
            Logger.warning(
              "summarize_step failed for session_id=#{session_id}: #{inspect(reason)}"
            )

            {:error, %{code: :summarization_failed, message: inspect(reason)}}
        end
      end
    )
  end

  def append_step(%{session_id: session_id, observation: observation, action: action}) do
    case Mnemosyne.append_async(session_id, observation, action) do
      :ok ->
        Logger.debug("Queued async append for session_id=#{session_id}")
        {:ok, %{session_id: session_id}}

      {:error, error} ->
        Logger.debug(
          "Failed to queue async append for session_id=#{session_id}: #{Exception.message(error)}"
        )

        normalize_error(error)
    end
  end

  def close_async(%{session_id: session_id}) do
    callback = fn
      {:ok, _} ->
        Logger.debug("Async close completed for session_id=#{session_id}")
        persist_session_finish(session_id)

      {:error, reason} ->
        Logger.warning("Async close failed for session_id=#{session_id}: #{inspect(reason)}")
    end

    case Mnemosyne.close_async(session_id, callback) do
      :ok ->
        Logger.debug("Queued async close for session_id=#{session_id}")
        {:ok, %{session_id: session_id, state: :closing}}

      {:error, error} ->
        Logger.debug(
          "Failed to queue async close for session_id=#{session_id}: #{Exception.message(error)}"
        )

        normalize_error(error)
    end
  end

  def commit_session(%{session_id: session_id, project_id: project_id, goal: goal} = attrs) do
    new_session_attrs = %{
      project_id: project_id,
      goal: goal,
      agent: Map.get(attrs, :agent),
      thread_id: Map.get(attrs, :thread_id)
    }

    callback = fn
      {:ok, _} ->
        Logger.debug("Committed session_id=#{session_id}, will start new session")
        persist_session_finish(session_id)

      {:error, reason} ->
        Logger.warning("Commit failed for session_id=#{session_id}: #{inspect(reason)}")
    end

    case Mnemosyne.close_async(session_id, callback) do
      :ok ->
        Logger.debug("Queued async close for session_id=#{session_id}, starting new session")
        persist_session_finish(session_id)
        start_session(new_session_attrs)

      {:error, error} ->
        Logger.debug("Failed to commit session_id=#{session_id}: #{Exception.message(error)}")
        normalize_error(error)
    end
  end

  def recall(%{project_id: project_id, query: query} = attrs) do
    project = root_memory_descriptor(project_id)
    session_id = Map.get(attrs, :session_id)

    case recall_call(project.repo_id, query, session_id) do
      {:ok, %{reasoned: reasoned, touched_nodes: touched}} ->
        {:ok,
         %{
           project_id: project_id,
           query: query,
           session_id: session_id,
           memory: Serializer.reasoned_memory(reasoned),
           touched_node_ids: Enum.map(touched, & &1.id)
         }}

      {:error, error} ->
        normalize_error(error)
    end
  end

  def get_node(%{project_id: project_id, node_id: node_id}) do
    project = root_memory_descriptor(project_id)
    repo_id = project.repo_id

    case Mnemosyne.get_node(repo_id, node_id) do
      {:ok, nil} ->
        {:ok,
         %{
           project_id: project_id,
           node_id: node_id,
           node: nil,
           metadata: nil,
           linked_nodes: []
         }}

      {:ok, %{} = node} ->
        with {:ok, metadata_map} <- Mnemosyne.get_metadata(repo_id, [node_id]),
             {:ok, linked_nodes} <- Mnemosyne.get_linked_nodes(repo_id, node_links(node)) do
          {:ok,
           %{
             project_id: project_id,
             node_id: node_id,
             node: node |> Serializer.node() |> Serializer.without_embedding(),
             metadata: Serializer.metadata(Map.get(metadata_map, node_id)),
             linked_nodes:
               Enum.map(linked_nodes, &(Serializer.node(&1) |> Serializer.without_embedding()))
           }}
        else
          {:error, error} -> normalize_error(error)
        end

      {:error, error} ->
        normalize_error(error)
    end
  end

  def latest_memories(%{project_id: project_id} = attrs) do
    project = root_memory_descriptor(project_id)
    top_k = Map.get(attrs, :top_k, 10)
    types = Map.get(attrs, :types, [:semantic, :episodic])
    opts = [types: types]

    case Mnemosyne.latest(project.repo_id, top_k, opts) do
      {:ok, memories} ->
        {:ok,
         %{
           project_id: project_id,
           memories:
             Enum.map(memories, fn {node, meta} ->
               %{
                 node: node |> Serializer.node() |> Serializer.without_embedding(),
                 metadata: Serializer.metadata(meta)
               }
             end)
         }}

      {:error, error} ->
        normalize_error(error)
    end
  end

  def session_state(session_id) do
    case Mnemosyne.session_state(session_id) do
      state when is_atom(state) -> {:ok, %{session_id: session_id, state: state}}
      {:error, error} -> normalize_error(error)
    end
  end

  @spec inspector_data(String.t()) :: {:ok, %{String.t() => struct()}} | {:error, map()}
  def inspector_data(project_id) when is_binary(project_id) do
    project = root_memory_descriptor(project_id)
    graph = load_graph(project.repo_id)
    {:ok, graph.nodes}
  rescue
    error ->
      {:error, %{code: :inspector_data_failed, message: Exception.message(error)}}
  end

  defp persist_session_open(project_key, session_id, goal) do
    Projects.create_session(%{
      project_key: project_key,
      session_id: session_id,
      goal: goal
    })
  end

  defp persist_session_finish(session_id) do
    Projects.finish_session(session_id)
  end

  defp normalize_error(%NotFoundError{resource: :repo, id: id}) do
    {:error, %{code: :project_not_open, message: "project repo is not open", id: id}}
  end

  defp normalize_error(%NotFoundError{resource: :session, id: id}) do
    {:error, %{code: :session_not_found, message: "session was not found", id: id}}
  end

  defp normalize_error(%SessionError{} = error) do
    {:error, %{code: :invalid_session_state, message: Exception.message(error)}}
  end

  defp normalize_error(error) do
    {:error, %{code: :memory_operation_failed, message: Exception.message(error)}}
  end

  defp project_result(project, already_open?) do
    project
    |> Map.drop([:backend, :dets_path])
    |> Map.put(:already_open?, already_open?)
  end

  defp recall_call(repo_id, query, nil) do
    Mnemosyne.recall(repo_id, query)
  end

  defp recall_call(repo_id, query, session_id) do
    Mnemosyne.recall_in_context(repo_id, session_id, query)
  end

  defp root_memory_descriptor(project_id) do
    case Projects.get_root_memory!(project_id) do
      memory ->
        %{project_id: project_id, repo_id: memory.repo_id, dets_path: memory.dets_path}
    end
  rescue
    Ecto.NoResultsError ->
      project = ProjectRegistry.resolve(project_id)
      %{project_id: project_id, repo_id: project.repo_id, dets_path: project.root_memory_path}
  end

  defp node_links(node) do
    case Map.get(node, :links) do
      links when is_map(links) ->
        Enum.flat_map(links, fn {_type, ids} -> MapSet.to_list(ids) end)

      _ ->
        []
    end
  end

  defp typed_link_count(links) when is_map(links) do
    Enum.reduce(links, 0, fn {_type, ids}, acc -> acc + MapSet.size(ids) end)
  end

  defp load_graph(repo_id) do
    case Mnemosyne.get_graph(repo_id) do
      %Mnemosyne.Graph{} = graph -> graph
      _ -> Mnemosyne.Graph.new()
    end
  end

  defp session_node_ids(_project_id, nil), do: []

  defp session_node_ids(_project_id, session_id) do
    Projects.get_session_node_ids(session_id)
  end

  defp backend_for_path(dets_path) do
    {Mnemosyne.GraphBackends.InMemory,
     persistence: {Mnemosyne.GraphBackends.Persistence.DETS, path: dets_path}}
  end

  defp ensure_memory_storage_root!(%{dets_path: dets_path}) when is_binary(dets_path) do
    dets_path
    |> Path.dirname()
    |> File.mkdir_p!()
  end
end
