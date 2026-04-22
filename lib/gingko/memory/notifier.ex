defmodule Gingko.Memory.Notifier do
  @moduledoc """
  Mnemosyne notifier adapter for Gingko monitor events.

  Translates Mnemosyne runtime events into Gingko monitor events,
  updates session tracking in SQLite, and rebroadcasts to Phoenix PubSub.
  """

  @behaviour Mnemosyne.Notifier

  require Logger

  alias Gingko.Memory
  alias Gingko.Memory.ActivityStore
  alias Gingko.Memory.ProjectRegistry
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects
  alias Gingko.Summaries.Config, as: SummariesConfig
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic

  @memory_appended_event [:mnemosyne, :memory, :appended]
  @deferred_events [:decay_completed, :consolidation_completed, :validation_completed]

  @impl true
  def notify(repo_id, event) do
    with {:ok, project_id} <- ProjectRegistry.decode_repo_id(repo_id),
         {:ok, %SessionMonitorEvent{} = normalized} <-
           normalize_event(project_id, repo_id, event) do
      maybe_emit_memory_appended(project_id, repo_id, event)

      if normalized.type in @deferred_events do
        defer_notification(project_id, repo_id, normalized)
      else
        finalize_notification(project_id, normalized)
      end
    end

    :ok
  end

  defp defer_notification(project_id, repo_id, normalized) do
    Task.Supervisor.start_child(Gingko.TaskSupervisor, fn ->
      enriched = %{normalized | summary: Map.merge(normalized.summary, graph_stats(repo_id))}
      finalize_notification(project_id, enriched)
    end)
  end

  defp finalize_notification(project_id, normalized) do
    update_session_trajectory(normalized)
    touch_session_activity(normalized)
    finish_session_if_terminal(normalized)
    ActivityStore.push(normalized)
    maybe_bump_cluster_version(normalized)
    broadcast(project_id, normalized)
  end

  defp normalize_event(project_id, repo_id, {:changeset_applied, changeset, _meta}) do
    node_ids = changeset_node_ids(changeset)

    {:ok,
     event(project_id, repo_id, :changeset_applied,
       node_ids: node_ids,
       summary: %{
         node_count: length(node_ids),
         link_count: length(changeset.links)
       }
     )}
  end

  defp normalize_event(project_id, repo_id, {:nodes_deleted, node_ids, _meta})
       when is_list(node_ids) do
    filtered_ids = Enum.filter(node_ids, &is_binary/1)

    {:ok,
     event(project_id, repo_id, :nodes_deleted,
       node_ids: filtered_ids,
       summary: %{deleted_count: length(filtered_ids)}
     )}
  end

  defp normalize_event(project_id, repo_id, {:decay_completed, summary, _meta})
       when is_map(summary) do
    {:ok, event(project_id, repo_id, :decay_completed, summary: summary)}
  end

  defp normalize_event(project_id, repo_id, {:consolidation_completed, summary, _meta})
       when is_map(summary) do
    {:ok, event(project_id, repo_id, :consolidation_completed, summary: summary)}
  end

  defp normalize_event(project_id, repo_id, {:validation_completed, summary, _meta})
       when is_map(summary) do
    {:ok, event(project_id, repo_id, :validation_completed, summary: summary)}
  end

  defp normalize_event(
         project_id,
         repo_id,
         {:session_transition, session_id, :idle, :collecting, _meta}
       )
       when is_binary(session_id) do
    {:ok,
     event(project_id, repo_id, :session_started,
       session_id: session_id,
       summary: %{state: :collecting, previous_state: :idle}
     )}
  end

  defp normalize_event(
         project_id,
         repo_id,
         {:session_transition, session_id, from, :idle, meta}
       )
       when is_binary(session_id) and from in [:ready, :extracting] do
    node_ids = Map.get(meta, :node_ids, [])

    {:ok,
     event(project_id, repo_id, :session_committed,
       session_id: session_id,
       node_ids: node_ids,
       summary: %{state: :idle, previous_state: from, node_count: length(node_ids)}
     )}
  end

  defp normalize_event(
         project_id,
         repo_id,
         {:session_transition, session_id, old_state, new_state, _meta}
       )
       when is_binary(session_id) do
    {:ok,
     event(project_id, repo_id, :session_state_changed,
       session_id: session_id,
       summary: %{state: new_state, previous_state: old_state}
     )}
  end

  defp normalize_event(project_id, repo_id, {:recall_executed, query, result, meta})
       when is_binary(query) do
    base = %{
      query: query,
      result: recall_result_summary(result),
      query_snippet: String.slice(query, 0, 80)
    }

    enriched = enrich_recall_summary(base, query, meta)

    {:ok, event(project_id, repo_id, :recall_executed, summary: enriched)}
  end

  defp normalize_event(project_id, repo_id, {:recall_failed, query, reason, _meta})
       when is_binary(query) do
    {:ok,
     event(project_id, repo_id, :recall_failed,
       summary: %{
         query: query,
         reason: inspect(reason),
         query_snippet: String.slice(query, 0, 80)
       }
     )}
  end

  defp normalize_event(
         project_id,
         repo_id,
         {:step_appended, session_id, %{step_index: step_index, trajectory_id: traj_id} = info,
          meta}
       )
       when is_binary(session_id) do
    base = %{
      step_index: step_index,
      trajectory_id: traj_id,
      boundary_detected: Map.get(info, :boundary_detected, false)
    }

    enriched = enrich_step_summary(base, meta)

    {:ok,
     event(project_id, repo_id, :step_appended,
       session_id: session_id,
       summary: enriched
     )}
  end

  defp normalize_event(
         project_id,
         repo_id,
         {:trajectory_committed, session_id, traj_id,
          %{node_count: node_count, node_ids: node_ids}, _meta}
       )
       when is_binary(session_id) and is_binary(traj_id) do
    {:ok,
     event(project_id, repo_id, :trajectory_committed,
       session_id: session_id,
       node_ids: node_ids,
       summary: %{trajectory_id: traj_id, node_count: node_count}
     )}
  end

  defp normalize_event(
         project_id,
         repo_id,
         {:trajectory_flushed, session_id, traj_id, %{node_count: node_count, node_ids: node_ids},
          _meta}
       )
       when is_binary(session_id) and is_binary(traj_id) do
    {:ok,
     event(project_id, repo_id, :trajectory_flushed,
       session_id: session_id,
       node_ids: node_ids,
       summary: %{trajectory_id: traj_id, node_count: node_count}
     )}
  end

  defp normalize_event(project_id, repo_id, {:session_expired, session_id, _meta})
       when is_binary(session_id) do
    {:ok,
     event(project_id, repo_id, :session_expired,
       session_id: session_id,
       summary: %{}
     )}
  end

  defp normalize_event(
         project_id,
         repo_id,
         {:trajectory_extraction_failed, session_id, traj_id, reason, _meta}
       )
       when is_binary(session_id) and is_binary(traj_id) do
    {:ok,
     event(project_id, repo_id, :trajectory_extraction_failed,
       session_id: session_id,
       summary: %{trajectory_id: traj_id, reason: inspect(reason)}
     )}
  end

  defp normalize_event(project_id, repo_id, {:write_failed, operation, reason, _meta}) do
    Logger.warning("Write failed for #{repo_id}: #{operation} - #{inspect(reason)}")

    {:ok,
     event(project_id, repo_id, :write_failed,
       summary: %{operation: operation, reason: inspect(reason)}
     )}
  end

  defp normalize_event(project_id, repo_id, {:write_crashed, operation, reason, _meta}) do
    Logger.error("Write crashed for #{repo_id}: #{operation} - #{inspect(reason)}")

    {:ok,
     event(project_id, repo_id, :write_crashed,
       summary: %{operation: operation, reason: inspect(reason)}
     )}
  end

  defp normalize_event(_project_id, _repo_id, _event), do: :ignore

  defp update_session_trajectory(%SessionMonitorEvent{
         session_id: session_id,
         node_ids: node_ids
       })
       when is_binary(session_id) and node_ids != [] do
    Projects.update_session_trajectory(%{session_id: session_id, node_ids: node_ids})
  end

  defp update_session_trajectory(_event), do: :ok

  defp touch_session_activity(%SessionMonitorEvent{
         type: :step_appended,
         session_id: session_id
       })
       when is_binary(session_id) do
    Projects.touch_session(session_id)
  end

  defp touch_session_activity(_event), do: :ok

  defp finish_session_if_terminal(%SessionMonitorEvent{
         type: type,
         session_id: session_id
       })
       when type in [:session_expired, :session_committed] and is_binary(session_id) do
    Projects.finish_session(session_id)
  end

  defp finish_session_if_terminal(_event), do: :ok

  @graph_mutating_events [
    :changeset_applied,
    :nodes_deleted,
    :consolidation_completed,
    :decay_completed,
    :validation_completed
  ]

  defp maybe_bump_cluster_version(%SessionMonitorEvent{type: type, project_id: project_id})
       when type in @graph_mutating_events do
    Gingko.Memory.GraphCluster.bump_version(project_id)
  end

  defp maybe_bump_cluster_version(_event), do: :ok

  defp broadcast(project_id, event) do
    Phoenix.PubSub.broadcast(
      Gingko.PubSub,
      Memory.project_monitor_topic(project_id),
      {:memory_event, event}
    )
  end

  defp event(project_id, repo_id, type, attrs) do
    struct!(SessionMonitorEvent, %{
      type: type,
      project_id: project_id,
      repo_id: repo_id,
      timestamp: DateTime.utc_now(),
      session_id: Keyword.get(attrs, :session_id),
      node_ids: Keyword.get(attrs, :node_ids, []),
      summary: Keyword.get(attrs, :summary, %{})
    })
  end

  defp enrich_recall_summary(base, _query, %{
         trace: %{result_count: _, mode: _, duration_us: _} = trace
       }) do
    Map.merge(base, %{
      result_count: trace.result_count,
      search_mode: trace.mode,
      duration_ms: trace.duration_us / 1000
    })
  end

  defp enrich_recall_summary(base, _query, _meta), do: base

  defp enrich_step_summary(base, %{trace: %{subgoal: _, reward: _} = trace}) do
    Map.merge(base, %{
      subgoal: trace.subgoal,
      reward: trace.reward
    })
  end

  defp enrich_step_summary(base, _meta), do: base

  defp graph_stats(repo_id) do
    case Mnemosyne.get_graph(repo_id) do
      %{nodes: nodes} ->
        {total_nodes, total_link_count, orphan_count, confidence_sum, semantic_count} =
          Enum.reduce(Map.values(nodes), {0, 0, 0, 0.0, 0}, &accumulate_graph_stats/2)

        avg_confidence =
          if semantic_count > 0, do: confidence_sum / semantic_count, else: 0.0

        %{
          graph_total_nodes: total_nodes,
          graph_total_edges: div(total_link_count, 2),
          graph_orphan_count: orphan_count,
          graph_avg_confidence: avg_confidence
        }

      _ ->
        %{}
    end
  end

  defp accumulate_graph_stats(node, {n, links, orphans, conf_sum, sem_count}) do
    link_size =
      Enum.reduce(node.links, 0, fn {_type, ids}, acc -> acc + MapSet.size(ids) end)

    is_orphan = if link_size == 0, do: 1, else: 0
    {conf_delta, sem_delta} = semantic_contribution(node)

    {n + 1, links + link_size, orphans + is_orphan, conf_sum + conf_delta, sem_count + sem_delta}
  end

  defp semantic_contribution(%Mnemosyne.Graph.Node.Semantic{confidence: c}), do: {c, 1}
  defp semantic_contribution(_), do: {0.0, 0}

  defp changeset_node_ids(changeset) do
    changeset
    |> Map.get(:additions, [])
    |> Enum.map(&Map.get(&1, :id))
    |> Enum.filter(&is_binary/1)
  end

  defp recall_result_summary({:ok, result}) do
    %{status: :ok, has_result?: not is_nil(result)}
  end

  defp recall_result_summary({:error, reason}) do
    %{status: :error, reason: inspect(reason)}
  end

  defp recall_result_summary(_result) do
    %{status: :unknown}
  end

  defp maybe_emit_memory_appended(project_id, repo_id, {:changeset_applied, changeset, _meta}) do
    if SummariesConfig.enabled?() do
      memory_nodes = Enum.filter(changeset.additions, &memory_node?/1)
      tags_by_memory = tags_by_memory_from_changeset(changeset)
      spawn_memory_appended_emit(project_id, repo_id, memory_nodes, tags_by_memory)
    else
      :ok
    end
  end

  defp maybe_emit_memory_appended(_project_id, _repo_id, _event), do: :ok

  defp spawn_memory_appended_emit(_project_id, _repo_id, [], _tags_by_memory), do: :ok

  defp spawn_memory_appended_emit(project_id, repo_id, memory_nodes, tags_by_memory) do
    Task.Supervisor.start_child(Gingko.TaskSupervisor, fn ->
      emit_memory_appended(project_id, repo_id, memory_nodes, tags_by_memory)
    end)

    :ok
  end

  defp emit_memory_appended(project_id, repo_id, memory_nodes, tags_by_memory) do
    graph = Mnemosyne.get_graph(repo_id)

    Enum.each(memory_nodes, fn node ->
      tag_ids = Map.get(tags_by_memory, node.id, [])
      linked_tags = build_linked_tags(graph, tag_ids)

      :telemetry.execute(
        @memory_appended_event,
        %{},
        %{
          project_key: project_id,
          node: %{id: node.id},
          linked_tags: linked_tags
        }
      )
    end)

    :ok
  rescue
    error in [KeyError, MatchError, FunctionClauseError, Mnemosyne.Errors.Framework.NotFoundError] ->
      Logger.warning(
        "memory appended bridge failed for project=#{project_id} repo=#{repo_id}: " <>
          "#{Exception.message(error)}\n" <> Exception.format_stacktrace(__STACKTRACE__)
      )

      :ok
  end

  defp memory_node?(%Semantic{}), do: true
  defp memory_node?(%Procedural{}), do: true
  defp memory_node?(%Episodic{}), do: true
  defp memory_node?(_), do: false

  # Tuple ordering is `{tag_id, memory_id, :membership}` per
  # deps/mnemosyne/lib/mnemosyne/pipeline/structuring.ex where membership links are constructed.
  defp tags_by_memory_from_changeset(%{links: links}) when is_list(links) do
    Enum.reduce(links, %{}, fn
      {tag_id, memory_id, :membership}, acc
      when is_binary(tag_id) and is_binary(memory_id) ->
        Map.update(acc, memory_id, [tag_id], &[tag_id | &1])

      _other, acc ->
        acc
    end)
  end

  defp tags_by_memory_from_changeset(_changeset), do: %{}

  defp build_linked_tags(%Mnemosyne.Graph{} = graph, tag_ids) do
    tag_ids
    |> Enum.uniq()
    |> Enum.flat_map(fn tag_id ->
      case Map.get(graph.nodes, tag_id) do
        %Mnemosyne.Graph.Node.Tag{id: id, label: label, links: links} ->
          [%{id: id, label: label, memory_count: membership_count(links)}]

        _other ->
          []
      end
    end)
  end

  defp build_linked_tags(_graph, _tag_ids), do: []

  defp membership_count(links) when is_map(links) do
    case Map.get(links, :membership) do
      %MapSet{} = ids -> MapSet.size(ids)
      _ -> 0
    end
  end

  defp membership_count(_links), do: 0
end
