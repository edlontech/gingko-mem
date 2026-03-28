defmodule Gingko.Memory.NotifierTest do
  use ExUnit.Case, async: false
  use Mimic
  alias Gingko.Memory.Notifier
  alias Gingko.Memory.ProjectRegistry
  alias Gingko.Memory.SessionMonitorEvent
  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.Notifier.Trace

  setup :set_mimic_global

  setup do
    project_id = "notifier-test-" <> Integer.to_string(System.unique_integer([:positive]))
    repo_id = ProjectRegistry.resolve(project_id).repo_id
    topic = Gingko.Memory.project_monitor_topic(project_id)

    Phoenix.PubSub.subscribe(Gingko.PubSub, topic)

    %{project_id: project_id, repo_id: repo_id, topic: topic}
  end

  test "session transition from idle to collecting emits session_started", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    assert :ok =
             Notifier.notify(repo_id, {:session_transition, "session-1", :idle, :collecting, %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :session_started,
                      project_id: ^project_id,
                      session_id: "session-1"
                    }}
  end

  test "changeset_applied emits graph event", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    changeset =
      Changeset.new()
      |> Changeset.add_node(%Tag{id: "tag-1", label: "Tag 1"})
      |> Changeset.add_node(%{id: nil})

    assert :ok = Notifier.notify(repo_id, {:changeset_applied, changeset, %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :changeset_applied,
                      project_id: ^project_id,
                      node_ids: ["tag-1"],
                      summary: %{node_count: 1}
                    }}
  end

  test "nodes_deleted summary count matches filtered node ids", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    assert :ok = Notifier.notify(repo_id, {:nodes_deleted, ["node-1", :bad, "node-2", 123], %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :nodes_deleted,
                      project_id: ^project_id,
                      node_ids: ["node-1", "node-2"],
                      summary: %{deleted_count: 2}
                    }}
  end

  test "ready to idle transition emits session_committed", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    assert :ok =
             Notifier.notify(
               repo_id,
               {:session_transition, "session-1", :ready, :idle, %{node_ids: ["tag-2"]}}
             )

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :session_committed,
                      project_id: ^project_id,
                      session_id: "session-1",
                      node_ids: ["tag-2"],
                      summary: %{node_count: 1}
                    }}
  end

  test "extracting to idle transition emits session_committed (auto_commit path)", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    node_ids = ["src_1", "ep_1", "sem_1"]

    assert :ok =
             Notifier.notify(
               repo_id,
               {:session_transition, "session-1", :extracting, :idle, %{node_ids: node_ids}}
             )

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :session_committed,
                      project_id: ^project_id,
                      session_id: "session-1",
                      node_ids: ^node_ids,
                      summary: %{node_count: 3, previous_state: :extracting}
                    }}
  end

  test "failed to idle transition does not emit session_committed", %{repo_id: repo_id} do
    assert :ok = Notifier.notify(repo_id, {:session_transition, "session-2", :failed, :idle, %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{type: :session_state_changed, session_id: "session-2"}}

    refute_receive {:memory_event, %SessionMonitorEvent{type: :session_committed}}
  end

  test "recall events are normalized", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    assert :ok = Notifier.notify(repo_id, {:recall_executed, "what changed?", {:ok, %{}}, %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :recall_executed,
                      project_id: ^project_id,
                      summary: %{query: "what changed?"}
                    }}
  end

  test "unknown repo ids are ignored and do not broadcast events", %{} do
    assert :ok =
             Notifier.notify(
               "invalid-repo-id",
               {:session_transition, "session-1", :idle, :collecting, %{}}
             )

    refute_receive {:memory_event, _}
  end

  test "recall_executed includes trace fields in summary", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    trace = %Trace.Recall{
      result_count: 5,
      mode: :semantic,
      duration_us: 12_500,
      candidate_count: 20,
      hops: 2
    }

    meta = %{trace: trace}
    query = "What happened during the last deploy?"

    assert :ok = Notifier.notify(repo_id, {:recall_executed, query, {:ok, %{}}, meta})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :recall_executed,
                      project_id: ^project_id,
                      summary: summary
                    }}

    assert summary.result_count == 5
    assert summary.search_mode == :semantic
    assert summary.duration_ms == 12.5
    assert summary.query_snippet == "What happened during the last deploy?"
  end

  test "recall_executed query_snippet truncates long queries", %{repo_id: repo_id} do
    long_query = String.duplicate("x", 120)
    meta = %{trace: %Trace.Recall{result_count: 0, mode: :keyword, duration_us: 100}}

    assert :ok = Notifier.notify(repo_id, {:recall_executed, long_query, {:ok, nil}, meta})

    assert_receive {:memory_event, %SessionMonitorEvent{summary: summary}}

    assert String.length(summary.query_snippet) == 80
  end

  test "recall_executed without trace still works", %{repo_id: repo_id} do
    assert :ok = Notifier.notify(repo_id, {:recall_executed, "test query", {:ok, %{}}, %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :recall_executed,
                      summary: %{query: "test query"}
                    }}
  end

  test "recall_failed includes query_snippet", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    long_query = String.duplicate("a", 100)

    assert :ok = Notifier.notify(repo_id, {:recall_failed, long_query, :timeout, %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :recall_failed,
                      project_id: ^project_id,
                      summary: summary
                    }}

    assert summary.query_snippet == String.slice(long_query, 0, 80)
    assert summary.reason == ":timeout"
  end

  test "step_appended includes subgoal and reward from trace", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    trace = %Trace.Episode{
      step_index: 3,
      trajectory_id: "traj-1",
      boundary_detected: true,
      subgoal: "Deploy the service",
      reward: 0.85
    }

    meta = %{session_id: "session-1", trace: trace}

    assert :ok =
             Notifier.notify(
               repo_id,
               {:step_appended, "session-1",
                %{step_index: 3, trajectory_id: "traj-1", boundary_detected: true}, meta}
             )

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :step_appended,
                      project_id: ^project_id,
                      session_id: "session-1",
                      summary: summary
                    }}

    assert summary.subgoal == "Deploy the service"
    assert summary.reward == 0.85
    assert summary.step_index == 3
  end

  test "step_appended without trace omits subgoal and reward", %{repo_id: repo_id} do
    meta = %{session_id: "session-1"}

    assert :ok =
             Notifier.notify(
               repo_id,
               {:step_appended, "session-1",
                %{step_index: 0, trajectory_id: "traj-2", boundary_detected: false}, meta}
             )

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :step_appended,
                      summary: summary
                    }}

    refute Map.has_key?(summary, :subgoal)
    refute Map.has_key?(summary, :reward)
  end

  test "changeset_applied includes link_count", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    changeset =
      Changeset.new()
      |> Changeset.add_node(%Tag{id: "tag-a", label: "A"})
      |> Changeset.add_node(%Tag{id: "tag-b", label: "B"})
      |> Changeset.add_link("tag-a", "tag-b", :sibling)
      |> Changeset.add_link("tag-a", "tag-c", :sibling)

    assert :ok = Notifier.notify(repo_id, {:changeset_applied, changeset, %{}})

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :changeset_applied,
                      project_id: ^project_id,
                      summary: %{node_count: 2, link_count: 2}
                    }}
  end

  describe "decay/consolidation graph stats" do
    setup %{repo_id: repo_id} do
      Mimic.copy(Mnemosyne)

      semantic_a = %Semantic{id: "sem-1", proposition: "fact A", confidence: 0.9}
      semantic_b = %Semantic{id: "sem-2", proposition: "fact B", confidence: 0.7}
      tag_node = %Tag{id: "tag-1", label: "orphan"}

      graph =
        Mnemosyne.Graph.new()
        |> Mnemosyne.Graph.put_node(semantic_a)
        |> Mnemosyne.Graph.put_node(semantic_b)
        |> Mnemosyne.Graph.put_node(tag_node)
        |> Mnemosyne.Graph.link("sem-1", "sem-2", :sibling)

      stub(Mnemosyne, :get_graph, fn ^repo_id -> graph end)

      %{graph: graph}
    end

    test "decay_completed includes graph stats", %{
      project_id: project_id,
      repo_id: repo_id
    } do
      assert :ok = Notifier.notify(repo_id, {:decay_completed, %{decayed: 2}, %{}})

      assert_receive {:memory_event,
                      %SessionMonitorEvent{
                        type: :decay_completed,
                        project_id: ^project_id,
                        summary: summary
                      }}

      assert summary.decayed == 2
      assert summary.graph_total_nodes == 3
      assert summary.graph_total_edges == 1
      assert summary.graph_orphan_count == 1
      assert_in_delta summary.graph_avg_confidence, 0.8, 0.01
    end

    test "consolidation_completed includes graph stats", %{
      project_id: project_id,
      repo_id: repo_id
    } do
      assert :ok =
               Notifier.notify(repo_id, {:consolidation_completed, %{merged: 1}, %{}})

      assert_receive {:memory_event,
                      %SessionMonitorEvent{
                        type: :consolidation_completed,
                        project_id: ^project_id,
                        summary: summary
                      }}

      assert summary.merged == 1
      assert summary.graph_total_nodes == 3
      assert summary.graph_total_edges == 1
      assert summary.graph_orphan_count == 1
      assert_in_delta summary.graph_avg_confidence, 0.8, 0.01
    end
  end

  test "trajectory_committed includes node_ids for session tracking", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    node_ids = ["sem-1", "sem-2", "tag-1"]

    assert :ok =
             Notifier.notify(
               repo_id,
               {:trajectory_committed, "session-1", "traj-1",
                %{node_count: 3, node_ids: node_ids}, %{}}
             )

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :trajectory_committed,
                      project_id: ^project_id,
                      session_id: "session-1",
                      node_ids: ^node_ids,
                      summary: %{trajectory_id: "traj-1", node_count: 3}
                    }}
  end

  test "trajectory_flushed includes node_ids for session tracking", %{
    project_id: project_id,
    repo_id: repo_id
  } do
    node_ids = ["proc-1", "proc-2"]

    assert :ok =
             Notifier.notify(
               repo_id,
               {:trajectory_flushed, "session-1", "traj-2", %{node_count: 2, node_ids: node_ids},
                %{}}
             )

    assert_receive {:memory_event,
                    %SessionMonitorEvent{
                      type: :trajectory_flushed,
                      project_id: ^project_id,
                      session_id: "session-1",
                      node_ids: ^node_ids,
                      summary: %{trajectory_id: "traj-2", node_count: 2}
                    }}
  end

  test "notifier propagates errors from finish_session", %{repo_id: repo_id} do
    Mimic.copy(Gingko.Projects)

    stub(Gingko.Projects, :finish_session, fn _session_id ->
      raise "db unavailable"
    end)

    assert_raise RuntimeError, "db unavailable", fn ->
      Notifier.notify(
        repo_id,
        {:session_transition, "session-1", :ready, :idle, %{node_ids: []}}
      )
    end
  end
end
