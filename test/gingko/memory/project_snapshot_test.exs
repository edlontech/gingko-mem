defmodule Gingko.Memory.ProjectSnapshotTest do
  use ExUnit.Case, async: true

  alias Gingko.Memory.ProjectSnapshot
  alias Gingko.Memory.SessionMonitorEvent

  describe "default_quality/0" do
    test "returns a map with all 7 quality keys" do
      assert %{
               total_nodes: 0,
               total_edges: 0,
               orphan_count: 0,
               avg_confidence: nil,
               last_decay_at: nil,
               last_consolidation_at: nil,
               last_validation_at: nil
             } = ProjectSnapshot.default_quality()
    end
  end

  describe "normalize_counters/1" do
    test "fills in missing keys with defaults" do
      assert %{active_sessions: 0, recent_commits: 0, recent_recalls: 0} =
               ProjectSnapshot.normalize_counters(%{})
    end

    test "preserves provided values" do
      assert %{active_sessions: 3, recent_commits: 1, recent_recalls: 2} =
               ProjectSnapshot.normalize_counters(%{
                 active_sessions: 3,
                 recent_commits: 1,
                 recent_recalls: 2
               })
    end
  end

  describe "apply_event/2 with :session_started" do
    test "appends the event to recent_events and adds the session to active_sessions" do
      snapshot = empty_snapshot()

      event = %SessionMonitorEvent{
        type: :session_started,
        project_id: "p",
        repo_id: "project:p",
        timestamp: DateTime.utc_now(),
        session_id: "s-1",
        summary: %{state: :collecting}
      }

      updated = ProjectSnapshot.apply_event(snapshot, event)

      assert [^event | _] = updated.recent_events
      assert [%{session_id: "s-1", state: :collecting}] = updated.active_sessions
      assert updated.counters.active_sessions == 1
    end
  end

  describe "apply_event/2 with :step_appended" do
    test "updates existing session's latest_activity_at and summary" do
      started_at = ~U[2026-04-01 00:00:00Z]
      stepped_at = ~U[2026-04-01 00:05:00Z]

      snapshot =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :session_started,
          project_id: "p",
          repo_id: "project:p",
          timestamp: started_at,
          session_id: "s-1",
          summary: %{state: :collecting}
        })

      step = %SessionMonitorEvent{
        type: :step_appended,
        project_id: "p",
        repo_id: "project:p",
        timestamp: stepped_at,
        session_id: "s-1",
        summary: %{node_count: 2}
      }

      updated = ProjectSnapshot.apply_event(snapshot, step)

      assert [%{session_id: "s-1", latest_activity_at: ^stepped_at, state: :collecting}] =
               updated.active_sessions
    end
  end

  describe "apply_event/2 with :session_committed" do
    test "removes the session from active_sessions" do
      started =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :session_started,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-committed",
          summary: %{state: :collecting}
        })

      updated =
        ProjectSnapshot.apply_event(started, %SessionMonitorEvent{
          type: :session_committed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-committed",
          summary: %{}
        })

      assert updated.active_sessions == []
      assert updated.counters.active_sessions == 0
      assert updated.counters.recent_commits == 1
    end
  end

  describe "apply_event/2 with :session_expired" do
    test "removes the session from active_sessions" do
      started =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :session_started,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-x",
          summary: %{state: :collecting}
        })

      updated =
        ProjectSnapshot.apply_event(started, %SessionMonitorEvent{
          type: :session_expired,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-x",
          summary: %{}
        })

      assert updated.active_sessions == []
    end
  end

  describe "apply_event/2 with :session_state_changed" do
    test "removes the session when the new state is terminal" do
      started =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :session_started,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-2",
          summary: %{state: :collecting}
        })

      terminated =
        ProjectSnapshot.apply_event(started, %SessionMonitorEvent{
          type: :session_state_changed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-2",
          summary: %{state: :committed}
        })

      assert terminated.active_sessions == []
    end

    test "updates the session's state when the new state is not terminal" do
      started =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :session_started,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-3",
          summary: %{state: :collecting}
        })

      updated =
        ProjectSnapshot.apply_event(started, %SessionMonitorEvent{
          type: :session_state_changed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "s-3",
          summary: %{state: :consolidating}
        })

      assert [%{session_id: "s-3", state: :consolidating}] = updated.active_sessions
    end
  end

  describe "apply_event/2 with :changeset_applied" do
    test "increments total_nodes and total_edges from summary counts" do
      snapshot = %{
        empty_snapshot()
        | quality: %{ProjectSnapshot.default_quality() | total_nodes: 3, total_edges: 2}
      }

      event = %SessionMonitorEvent{
        type: :changeset_applied,
        project_id: "p",
        repo_id: "project:p",
        timestamp: DateTime.utc_now(),
        summary: %{node_count: 4, link_count: 5}
      }

      updated = ProjectSnapshot.apply_event(snapshot, event)
      assert updated.quality.total_nodes == 7
      assert updated.quality.total_edges == 7
    end
  end

  describe "apply_event/2 with :nodes_deleted" do
    test "decrements total_nodes by deleted_count, clamped at zero" do
      snapshot = %{
        empty_snapshot()
        | quality: %{ProjectSnapshot.default_quality() | total_nodes: 5}
      }

      updated =
        ProjectSnapshot.apply_event(snapshot, %SessionMonitorEvent{
          type: :nodes_deleted,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          summary: %{deleted_count: 3}
        })

      assert updated.quality.total_nodes == 2
    end

    test "never goes below zero" do
      snapshot = %{
        empty_snapshot()
        | quality: %{ProjectSnapshot.default_quality() | total_nodes: 1}
      }

      updated =
        ProjectSnapshot.apply_event(snapshot, %SessionMonitorEvent{
          type: :nodes_deleted,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          summary: %{deleted_count: 10}
        })

      assert updated.quality.total_nodes == 0
    end
  end

  describe "apply_event/2 with :decay_completed" do
    test "sets last_decay_at and overwrites graph totals from summary" do
      ts = ~U[2026-04-15 12:00:00Z]

      updated =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :decay_completed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: ts,
          summary: %{
            graph_total_nodes: 10,
            graph_total_edges: 6,
            graph_orphan_count: 1,
            graph_avg_confidence: 0.85
          }
        })

      assert updated.quality.last_decay_at == ts
      assert updated.quality.total_nodes == 10
      assert updated.quality.total_edges == 6
      assert updated.quality.orphan_count == 1
      assert updated.quality.avg_confidence == 0.85
    end
  end

  describe "apply_event/2 with :consolidation_completed" do
    test "sets last_consolidation_at" do
      ts = ~U[2026-04-16 12:00:00Z]

      updated =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :consolidation_completed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: ts,
          summary: %{}
        })

      assert updated.quality.last_consolidation_at == ts
    end
  end

  describe "apply_event/2 with :validation_completed" do
    test "sets last_validation_at" do
      ts = ~U[2026-04-17 12:00:00Z]

      updated =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :validation_completed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: ts,
          summary: %{}
        })

      assert updated.quality.last_validation_at == ts
    end
  end

  describe "apply_event/2 with :recall_executed" do
    test "increments recent_recalls counter" do
      updated =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :recall_executed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: nil,
          summary: %{}
        })

      assert updated.counters.recent_recalls == 1
    end

    test "updates latest_activity_at on an existing session only" do
      started_ts = ~U[2026-04-01 00:00:00Z]
      recall_ts = ~U[2026-04-01 00:10:00Z]

      started =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :session_started,
          project_id: "p",
          repo_id: "project:p",
          timestamp: started_ts,
          session_id: "s-r",
          summary: %{state: :collecting}
        })

      updated =
        ProjectSnapshot.apply_event(started, %SessionMonitorEvent{
          type: :recall_executed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: recall_ts,
          session_id: "s-r",
          summary: %{}
        })

      assert [%{session_id: "s-r", latest_activity_at: ^recall_ts}] = updated.active_sessions
    end

    test "does not create a new session for an unknown session_id" do
      updated =
        ProjectSnapshot.apply_event(empty_snapshot(), %SessionMonitorEvent{
          type: :recall_executed,
          project_id: "p",
          repo_id: "project:p",
          timestamp: DateTime.utc_now(),
          session_id: "unknown",
          summary: %{}
        })

      assert updated.active_sessions == []
    end
  end

  describe "apply_event/2 trims recent_events to max size" do
    test "retains at most 100 recent events" do
      snapshot = empty_snapshot()
      now = DateTime.utc_now()

      snapshot =
        Enum.reduce(1..105, snapshot, fn i, acc ->
          event = %SessionMonitorEvent{
            type: :recall_executed,
            project_id: "p",
            repo_id: "project:p",
            timestamp: DateTime.add(now, i, :second),
            session_id: nil,
            summary: %{n: i}
          }

          ProjectSnapshot.apply_event(acc, event)
        end)

      assert length(snapshot.recent_events) == 100
    end
  end

  defp empty_snapshot do
    %{
      counters: %{active_sessions: 0, recent_commits: 0, recent_recalls: 0},
      quality: Gingko.Memory.ProjectSnapshot.default_quality(),
      active_sessions: [],
      past_sessions: [],
      recent_events: []
    }
  end
end
