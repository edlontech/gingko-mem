defmodule Gingko.Memory.ProjectSnapshot do
  @moduledoc """
  Pure snapshot transformations for the project detail LiveView shell.

  Given a `%{counters, quality, active_sessions, past_sessions, recent_events}`
  map and a `Gingko.Memory.SessionMonitorEvent`, produces an updated snapshot
  map with the event applied. Contains no socket, no PubSub, no I/O — only
  data transformations.
  """

  alias Gingko.Memory.SessionMonitorEvent

  @max_recent_events 100
  @terminal_states [:idle, :closed, :committed, :failed, :error, :terminated]

  @type quality :: %{
          total_nodes: non_neg_integer(),
          total_edges: non_neg_integer(),
          orphan_count: non_neg_integer(),
          avg_confidence: float() | nil,
          last_decay_at: DateTime.t() | nil,
          last_consolidation_at: DateTime.t() | nil,
          last_validation_at: DateTime.t() | nil
        }

  @type counters :: %{
          active_sessions: non_neg_integer(),
          recent_commits: non_neg_integer(),
          recent_recalls: non_neg_integer()
        }

  @type t :: %{
          counters: counters(),
          quality: quality(),
          active_sessions: [map()],
          past_sessions: [map()],
          recent_events: [SessionMonitorEvent.t()]
        }

  @spec default_quality() :: quality()
  def default_quality do
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

  @spec normalize_counters(map()) :: counters()
  def normalize_counters(counters) do
    %{
      active_sessions: Map.get(counters, :active_sessions, 0),
      recent_commits: Map.get(counters, :recent_commits, 0),
      recent_recalls: Map.get(counters, :recent_recalls, 0)
    }
  end

  @spec apply_event(t(), SessionMonitorEvent.t()) :: t()
  def apply_event(snapshot, %SessionMonitorEvent{} = event) do
    recent_events = Enum.take([event | snapshot.recent_events], @max_recent_events)
    active_sessions = update_active_sessions(snapshot.active_sessions, event)
    quality = update_quality(snapshot.quality, event)

    counters = %{
      active_sessions: length(active_sessions),
      recent_commits: Enum.count(recent_events, &(&1.type == :session_committed)),
      recent_recalls: Enum.count(recent_events, &(&1.type == :recall_executed))
    }

    %{
      snapshot
      | recent_events: recent_events,
        active_sessions: active_sessions,
        quality: quality,
        counters: counters
    }
  end

  defp update_active_sessions(active_sessions, %SessionMonitorEvent{session_id: nil}),
    do: active_sessions

  defp update_active_sessions(
         active_sessions,
         %SessionMonitorEvent{type: :session_started} = event
       ) do
    upsert_session(active_sessions, event.session_id, fn _existing ->
      %{
        session_id: event.session_id,
        state: Map.get(event.summary, :state, :collecting),
        latest_activity_at: event.timestamp,
        summary: event.summary
      }
    end)
  end

  defp update_active_sessions(active_sessions, %SessionMonitorEvent{type: :step_appended} = event) do
    upsert_session(active_sessions, event.session_id, fn existing ->
      %{
        session_id: event.session_id,
        state: Map.get(existing, :state, :collecting),
        latest_activity_at: event.timestamp,
        summary: event.summary
      }
    end)
  end

  defp update_active_sessions(
         active_sessions,
         %SessionMonitorEvent{type: :recall_executed} = event
       ) do
    if Enum.any?(active_sessions, &(&1.session_id == event.session_id)) do
      upsert_session(active_sessions, event.session_id, fn existing ->
        %{
          session_id: event.session_id,
          state: Map.get(existing, :state, :collecting),
          latest_activity_at: event.timestamp,
          summary: Map.get(existing, :summary, %{})
        }
      end)
    else
      active_sessions
    end
  end

  defp update_active_sessions(
         active_sessions,
         %SessionMonitorEvent{type: :session_committed} = event
       ) do
    Enum.reject(active_sessions, &(&1.session_id == event.session_id))
  end

  defp update_active_sessions(
         active_sessions,
         %SessionMonitorEvent{type: :session_expired} = event
       ) do
    Enum.reject(active_sessions, &(&1.session_id == event.session_id))
  end

  defp update_active_sessions(
         active_sessions,
         %SessionMonitorEvent{type: :session_state_changed} = event
       ) do
    next_state = Map.get(event.summary, :state)

    cond do
      next_state in @terminal_states ->
        Enum.reject(active_sessions, &(&1.session_id == event.session_id))

      Enum.any?(active_sessions, &(&1.session_id == event.session_id)) ->
        upsert_session(active_sessions, event.session_id, fn existing ->
          %{
            session_id: event.session_id,
            state: next_state || Map.get(existing, :state, :collecting),
            latest_activity_at: event.timestamp,
            summary: Map.get(existing, :summary, %{})
          }
        end)

      true ->
        active_sessions
    end
  end

  defp update_active_sessions(active_sessions, _event), do: active_sessions

  defp upsert_session(active_sessions, session_id, builder) do
    session_map =
      active_sessions
      |> Map.new(&{&1.session_id, &1})
      |> Map.update(session_id, builder.(%{}), &builder.(&1))

    session_map
    |> Map.values()
    |> Enum.sort_by(&session_sort_key/1, :desc)
  end

  defp session_sort_key(%{latest_activity_at: %DateTime{} = timestamp}) do
    DateTime.to_unix(timestamp, :microsecond)
  end

  defp session_sort_key(_session), do: -1

  defp update_quality(quality, %SessionMonitorEvent{type: :changeset_applied} = event) do
    %{
      quality
      | total_nodes: quality.total_nodes + Map.get(event.summary, :node_count, 0),
        total_edges: quality.total_edges + Map.get(event.summary, :link_count, 0)
    }
  end

  defp update_quality(quality, %SessionMonitorEvent{type: :nodes_deleted} = event) do
    deleted = Map.get(event.summary, :deleted_count, 0)
    %{quality | total_nodes: max(quality.total_nodes - deleted, 0)}
  end

  defp update_quality(quality, %SessionMonitorEvent{type: :decay_completed} = event) do
    apply_graph_correction(quality, event, :last_decay_at)
  end

  defp update_quality(quality, %SessionMonitorEvent{type: :consolidation_completed} = event) do
    apply_graph_correction(quality, event, :last_consolidation_at)
  end

  defp update_quality(quality, %SessionMonitorEvent{type: :validation_completed} = event) do
    apply_graph_correction(quality, event, :last_validation_at)
  end

  defp update_quality(quality, _event), do: quality

  defp apply_graph_correction(quality, event, timestamp_key) do
    Map.put(
      %{
        quality
        | total_nodes: Map.get(event.summary, :graph_total_nodes, quality.total_nodes),
          total_edges: Map.get(event.summary, :graph_total_edges, quality.total_edges),
          orphan_count: Map.get(event.summary, :graph_orphan_count, quality.orphan_count),
          avg_confidence: Map.get(event.summary, :graph_avg_confidence, quality.avg_confidence)
      },
      timestamp_key,
      event.timestamp
    )
  end
end
