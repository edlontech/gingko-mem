defmodule Gingko.Projects do
  @moduledoc false

  import Ecto.Query

  alias Gingko.Memory.ProjectRegistry
  alias Gingko.Projects.ExtractionOverlay
  alias Gingko.Projects.Project
  alias Gingko.Projects.ProjectMemory
  alias Gingko.Projects.Session
  alias Gingko.Repo

  @projects_topic "projects:updated"
  @overlays_topic "projects:overlays"

  def projects_topic, do: @projects_topic

  def overlays_topic, do: @overlays_topic

  def subscribe_projects do
    Phoenix.PubSub.subscribe(Gingko.PubSub, @projects_topic)
  end

  def subscribe_overlays do
    Phoenix.PubSub.subscribe(Gingko.PubSub, @overlays_topic)
  end

  def register_project(%{project_key: project_key} = attrs) when is_binary(project_key) do
    storage_root = Map.get(attrs, :storage_root, ProjectRegistry.storage_root())
    registry = ProjectRegistry.resolve(project_key, storage_root: storage_root)

    result =
      Repo.transact(fn ->
        case Repo.get_by(Project, project_key: project_key) do
          nil ->
            with {:ok, project} <-
                   %Project{}
                   |> Project.changeset(%{
                     project_key: project_key,
                     display_name: Map.get(attrs, :display_name, project_key)
                   })
                   |> Repo.insert(),
                 {:ok, _root_memory} <- create_root_memory(project, registry) do
              {:ok, {project, :created}}
            else
              {:error, changeset} -> {:error, changeset}
            end

          %Project{} = project ->
            {:ok, {project, :existing}}
        end
      end)

    case normalize_tx_result(result) do
      {:ok, project, :created} ->
        broadcast_projects_changed()
        {:ok, project}

      {:ok, project, :existing} ->
        {:ok, project}

      {:error, _} = error ->
        error
    end
  end

  def list_projects do
    Project
    |> order_by([project], asc: project.inserted_at)
    |> Repo.all()
  end

  def get_project_by_key!(project_key) do
    Repo.get_by!(Project, project_key: project_key)
  end

  def get_extraction_overlay(project_key) when is_binary(project_key) do
    project_key
    |> get_project_by_key!()
    |> ExtractionOverlay.from_project()
  end

  def update_extraction_overlay(project_key, attrs) when is_binary(project_key) do
    project = get_project_by_key!(project_key)

    with %Ecto.Changeset{valid?: true} = overlay_cs <-
           ExtractionOverlay.changeset(ExtractionOverlay.from_project(project), attrs),
         overlay <- Ecto.Changeset.apply_changes(overlay_cs),
         project_attrs <- ExtractionOverlay.to_project_attrs(overlay),
         {:ok, updated} <-
           project
           |> Project.changeset_overlay(project_attrs)
           |> Repo.update() do
      broadcast_overlay_updated(project_key)
      {:ok, updated}
    else
      %Ecto.Changeset{valid?: false} = cs -> {:error, cs}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  def reset_extraction_overlay(project_key) when is_binary(project_key) do
    update_extraction_overlay(project_key, %{
      "base" => "inherit_global",
      "domain_context" => nil,
      "steps" => %{},
      "value_function_overrides" => %{}
    })
  end

  def list_projects_with_inherit_global do
    Project
    |> where([p], p.overlay_base == "inherit_global")
    |> Repo.all()
  end

  def custom_overlays?(%Project{} = project) do
    project.overlay_base != "inherit_global" or
      overlay_map_nonempty?(project.overlay_steps) or
      is_binary(project.overlay_domain_context)
  end

  defp overlay_map_nonempty?(nil), do: false
  defp overlay_map_nonempty?(map) when is_map(map), do: map_size(map) > 0

  defp broadcast_overlay_updated(project_key) do
    Phoenix.PubSub.broadcast(
      Gingko.PubSub,
      @overlays_topic,
      {:overlay_updated, project_key}
    )
  end

  def get_root_memory!(project_key) do
    get_memory!(project_key, :root)
  end

  def get_memory!(project_key, selector) do
    project = get_project_by_key!(project_key)

    query =
      case selector do
        :root ->
          from(memory in ProjectMemory,
            where: memory.project_id == ^project.id and memory.kind == :root
          )

        {:branch, branch_name} ->
          from(memory in ProjectMemory,
            where:
              memory.project_id == ^project.id and memory.kind == :branch and
                memory.branch_name == ^branch_name
          )
      end

    Repo.one!(query)
  end

  def create_branch_memory(project_key, branch_name) when is_binary(branch_name) do
    project = get_project_by_key!(project_key)
    dets_path = ProjectRegistry.branch_memory_path(project_key, branch_name)

    %ProjectMemory{}
    |> ProjectMemory.changeset(%{
      project_id: project.id,
      kind: :branch,
      branch_name: branch_name,
      repo_id: ProjectRegistry.branch_repo_id(project_key, branch_name),
      dets_path: dets_path
    })
    |> Repo.insert()
  end

  def create_session(%{project_key: project_key, session_id: session_id} = attrs) do
    case Repo.get_by(Project, project_key: project_key) do
      nil ->
        {:error, :project_not_found}

      project ->
        %Session{}
        |> Session.changeset(%{
          project_id: project.id,
          session_id: session_id,
          status: "active",
          goal: Map.get(attrs, :goal),
          started_at: Map.get(attrs, :started_at, DateTime.utc_now())
        })
        |> Repo.insert(on_conflict: :nothing)
    end
  end

  def finish_session(session_id) do
    case Repo.get_by(Session, session_id: session_id) do
      nil ->
        {:error, :session_not_found}

      session ->
        session
        |> Session.changeset(%{status: "finished", finished_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  def abandon_active_sessions do
    now = DateTime.utc_now()

    Session
    |> where([s], s.status == "active")
    |> Repo.update_all(set: [status: "abandoned", finished_at: now, updated_at: now])
  end

  def touch_session(session_id) do
    Session
    |> where([s], s.session_id == ^session_id and s.status == "active")
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])
  end

  def update_session_trajectory(%{session_id: session_id, node_ids: new_node_ids}) do
    case Repo.get_by(Session, session_id: session_id) do
      nil ->
        {:error, :session_not_found}

      session ->
        merged_ids = Enum.uniq(session.node_ids ++ new_node_ids)

        session
        |> Session.changeset(%{
          node_ids: merged_ids,
          node_count: length(merged_ids),
          trajectory_count: session.trajectory_count + 1
        })
        |> Repo.update()
    end
  end

  def list_sessions(project_key, opts \\ []) do
    project = get_project_by_key!(project_key)
    limit = Keyword.get(opts, :limit, 25)
    status = Keyword.get(opts, :status)

    Session
    |> where([s], s.project_id == ^project.id)
    |> maybe_filter_status(status)
    |> order_by([s], desc: s.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_stale_active_sessions(%DateTime{} = cutoff) do
    Session
    |> where([s], s.status == "active" and s.updated_at < ^cutoff)
    |> preload(:project)
    |> Repo.all()
  end

  def get_session_node_ids(session_id) do
    case Repo.get_by(Session, session_id: session_id) do
      nil -> []
      session -> session.node_ids
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [s], s.status == ^status)

  defp create_root_memory(project, registry) do
    %ProjectMemory{}
    |> ProjectMemory.changeset(%{
      project_id: project.id,
      kind: :root,
      repo_id: ProjectRegistry.repo_id(project.project_key),
      dets_path: registry.root_memory_path
    })
    |> Repo.insert()
  end

  defp normalize_tx_result({:ok, {%Project{} = project, tag}}), do: {:ok, project, tag}
  defp normalize_tx_result({:error, changeset}), do: {:error, changeset}

  defp broadcast_projects_changed do
    Phoenix.PubSub.broadcast(Gingko.PubSub, @projects_topic, :projects_changed)
  end
end
