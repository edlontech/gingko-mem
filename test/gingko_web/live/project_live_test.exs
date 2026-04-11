defmodule GingkoWeb.ProjectLiveTest do
  use GingkoWeb.ConnCase, async: false
  use Mimic

  alias Gingko.Memory
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects
  alias Gingko.Projects.Project
  alias Gingko.Projects.ProjectMemory
  alias Gingko.Projects.Session
  alias Gingko.Repo
  alias Mnemosyne.Graph.Edge
  alias Mnemosyne.Graph.Node.Semantic

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup %{tmp_dir: tmp_dir} do
    Mimic.copy(Gingko.Memory)

    Repo.delete_all(Session)
    Repo.delete_all(ProjectMemory)
    Repo.delete_all(Project)

    stub(Memory, :project_monitor_snapshot, fn _project_id -> empty_snapshot() end)

    stub(Memory, :latest_memories, fn attrs ->
      {:ok, %{project_id: attrs[:project_id] || attrs.project_id, memories: []}}
    end)

    project_key = "project-live-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _project} =
      Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    %{project_id: project_key, tmp_dir: tmp_dir}
  end

  describe "routing" do
    test "unknown project_id returns 404", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/projects/does-not-exist/memories")
      end
    end

    test "unknown tab segment patches to /memories", %{conn: conn, project_id: project_id} do
      {:error, {:live_redirect, %{to: target}}} =
        live conn, ~p"/projects/#{project_id}/not-a-real-tab"

      assert target == "/projects/#{project_id}/memories"
    end

    test "missing tab (bare /projects/:id) patches to /memories", %{
      conn: conn,
      project_id: project_id
    } do
      {:error, {:live_redirect, %{to: target}}} =
        live conn, ~p"/projects/#{project_id}"

      assert target == "/projects/#{project_id}/memories"
    end

    test "/projects/:id/memories mounts and renders memories tab + status strip", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/memories"

      assert html =~ project_id
      assert html =~ "← Projects"
      assert html =~ "Recent Memories"
      assert html =~ "No recent memories found."
      refute html =~ "Tab &quot;memories&quot; not implemented yet."
      assert html =~ "0 active"
      assert html =~ "0 nodes"
      assert html =~ "live"
    end
  end

  describe "memories tab" do
    test "{:recent_memories, :change_top_k, k} reloads memories and updates select", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :latest_memories, fn attrs ->
        send(test_pid, {:latest_memories_called, attrs})
        {:ok, %{project_id: attrs[:project_id] || attrs.project_id, memories: []}}
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      send(view.pid, {:recent_memories, :change_top_k, 20})

      assert render(view) =~ ~s(value="20" selected)
      assert state_assigns(view).memories_top_k == 20
      assert_received {:latest_memories_called, %{project_id: ^project_id, top_k: 20}}
    end
  end

  describe "tab switching via push_patch" do
    test "switching tabs keeps the LiveView process alive and updates active_tab", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)
      stub(Memory, :inspector_data, fn ^project_id -> {:ok, %{}} end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      original_pid = view.pid

      new_path = ~p"/projects/#{project_id}/health"

      rendered =
        view
        |> element(~s|a[href="#{new_path}"][data-phx-link="patch"]|)
        |> render_click()

      assert_patch view, new_path
      assert rendered =~ "Total Nodes"
      assert rendered =~ "Low Confidence"
      refute rendered =~ "not implemented yet"
      assert Process.alive?(original_pid)
      assert original_pid == view.pid
    end

    test "each tab link is rendered", %{conn: conn, project_id: project_id} do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      for tab <- ~w(memories search graph health events) do
        assert view
               |> element(~s|a[href="/projects/#{project_id}/#{tab}"][data-phx-link="patch"]|)
               |> has_element?()
      end
    end
  end

  describe "status strip" do
    test "renders counters and live badge on mount", %{conn: conn, project_id: project_id} do
      stub(Memory, :project_monitor_snapshot, fn ^project_id ->
        empty_snapshot()
        |> Map.put(:quality, %{
          total_nodes: 42,
          total_edges: 7,
          orphan_count: 3,
          avg_confidence: 0.912,
          last_decay_at: nil,
          last_consolidation_at: nil,
          last_validation_at: nil
        })
        |> Map.put(:counters, %{active_sessions: 2, recent_commits: 0, recent_recalls: 0})
        |> Map.put(:active_sessions, [
          %{
            session_id: "s1",
            state: :collecting,
            latest_activity_at: DateTime.utc_now(),
            summary: %{}
          }
        ])
      end)

      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/memories"

      assert html =~ "2 active"
      assert html =~ "42 nodes"
      assert html =~ "3 orphans"
      assert html =~ "91.2% conf"
      assert html =~ "live"
    end

    test "avg_confidence nil hides the conf span", %{conn: conn, project_id: project_id} do
      stub(Memory, :project_monitor_snapshot, fn ^project_id ->
        Map.put(empty_snapshot(), :quality, %{
          total_nodes: 1,
          total_edges: 0,
          orphan_count: 0,
          avg_confidence: nil,
          last_decay_at: nil,
          last_consolidation_at: nil,
          last_validation_at: nil
        })
      end)

      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/memories"

      refute html =~ "% conf"
    end

    test "orphans span hidden when count is 0", %{conn: conn, project_id: project_id} do
      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/memories"

      refute html =~ "orphans"
    end

    test "active-sessions link targets events tab with sessions filter", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      assert view
             |> element(~s|a[href="/projects/#{project_id}/events?filter=sessions"]|)
             |> has_element?()
    end
  end

  describe "PubSub events" do
    test ":session_started updates counters.active_sessions in-place", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, html} = live conn, ~p"/projects/#{project_id}/memories"
      assert html =~ "0 active"

      event = %SessionMonitorEvent{
        type: :session_started,
        project_id: project_id,
        repo_id: "project:#{project_id}",
        timestamp: DateTime.utc_now(),
        session_id: "session-live-1",
        summary: %{state: :collecting}
      }

      Phoenix.PubSub.broadcast(
        Gingko.PubSub,
        Memory.project_monitor_topic(project_id),
        {:memory_event, event}
      )

      eventually(fn ->
        assert render(view) =~ "1 active"
      end)
    end

    test "events from other projects are ignored", %{
      conn: conn,
      project_id: project_id,
      tmp_dir: tmp_dir
    } do
      other_key = "other-#{System.unique_integer([:positive])}"
      {:ok, _} = Projects.register_project(%{project_key: other_key, storage_root: tmp_dir})

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      event = %SessionMonitorEvent{
        type: :session_started,
        project_id: other_key,
        repo_id: "project:#{other_key}",
        timestamp: DateTime.utc_now(),
        session_id: "foreign-session",
        summary: %{state: :collecting}
      }

      send(view.pid, {:memory_event, event})

      assert render(view) =~ "0 active"
    end
  end

  describe "memory refresh debounce" do
    test ":changeset_applied schedules a :refresh_memories timer (single within window)", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      refresh_event = fn ->
        %SessionMonitorEvent{
          type: :changeset_applied,
          project_id: project_id,
          repo_id: "project:#{project_id}",
          timestamp: DateTime.utc_now(),
          summary: %{node_count: 1, link_count: 1}
        }
      end

      for _ <- 1..5, do: send(view.pid, {:memory_event, refresh_event.()})

      :sys.get_state(view.pid)
      state = state_assigns(view)
      assert is_reference(state.memories_refresh_timer)

      first_timer_ref = state.memories_refresh_timer

      send(view.pid, {:memory_event, refresh_event.()})
      :sys.get_state(view.pid)
      state2 = state_assigns(view)
      refute state2.memories_refresh_timer == first_timer_ref
    end

    test "direct :refresh_memories clears the stored timer", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      send(
        view.pid,
        {:memory_event,
         %SessionMonitorEvent{
           type: :changeset_applied,
           project_id: project_id,
           repo_id: "project:#{project_id}",
           timestamp: DateTime.utc_now(),
           summary: %{}
         }}
      )

      :sys.get_state(view.pid)
      assert is_reference(state_assigns(view).memories_refresh_timer)

      send(view.pid, :refresh_memories)
      :sys.get_state(view.pid)
      assert state_assigns(view).memories_refresh_timer == nil
    end
  end

  describe "deep-link query params" do
    test "?node=abc on graph tab is parsed into active_params", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph?node=abc"

      assert %{node: "abc"} = state_assigns(view).active_params
      assert state_assigns(view).active_tab == "graph"
    end

    test "?filter=sessions&session_id=xyz is parsed into active_params on events tab", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} =
        live conn, ~p"/projects/#{project_id}/events?filter=sessions&session_id=xyz"

      assert %{filter: "sessions", session_id: "xyz"} = state_assigns(view).active_params
    end

    test "unknown query params are dropped", %{conn: conn, project_id: project_id} do
      {:ok, view, _html} =
        live conn, ~p"/projects/#{project_id}/graph?node=abc&other=drop-me"

      assert state_assigns(view).active_params == %{node: "abc"}
    end
  end

  describe "search tab" do
    test "initial assigns default to idle/nil/nil", %{conn: conn, project_id: project_id} do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/search"

      state = state_assigns(view)

      assert state.search_text == ""
      assert state.search_status == :idle
      assert state.search_result == nil
      assert state.search_task_ref == nil
    end

    test "{:search, :submit, query} spawns a Task.Supervisor child and assigns searching", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :recall, fn _ ->
        Process.sleep(1_000)
        {:ok, %{}}
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/search"

      %{active: before_active} = DynamicSupervisor.count_children(Gingko.TaskSupervisor)

      send(view.pid, {:search, :submit, "hello"})
      :sys.get_state(view.pid)

      state = state_assigns(view)
      assert state.search_status == :searching
      assert state.search_text == "hello"
      assert is_reference(state.search_task_ref)

      %{active: after_active} = DynamicSupervisor.count_children(Gingko.TaskSupervisor)
      assert after_active == before_active + 1
    end

    test "blank query does not spawn a task and leaves state idle", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/search"

      %{active: before_active} = DynamicSupervisor.count_children(Gingko.TaskSupervisor)

      send(view.pid, {:search, :submit, "   "})
      :sys.get_state(view.pid)

      state = state_assigns(view)
      assert state.search_status == :idle
      assert state.search_task_ref == nil

      %{active: after_active} = DynamicSupervisor.count_children(Gingko.TaskSupervisor)
      assert after_active == before_active
    end

    test "task result message transitions to :completed and caches result", %{
      conn: conn,
      project_id: project_id
    } do
      fake_ref = Process.monitor(self())
      Process.demonitor(fake_ref, [:flush])

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/search"

      :sys.replace_state(view.pid, fn state ->
        assigns = Map.put(state.socket.assigns, :search_task_ref, fake_ref)
        assigns = Map.put(assigns, :search_status, :searching)
        %{state | socket: %{state.socket | assigns: assigns}}
      end)

      result = %{
        project_id: project_id,
        query: "hello",
        session_id: nil,
        memory: %{semantic: "water is wet", episodic: nil, procedural: nil},
        touched_node_ids: ["n-1"]
      }

      send(view.pid, {fake_ref, {:ok, result}})
      :sys.get_state(view.pid)

      state = state_assigns(view)
      assert state.search_status == :completed
      assert state.search_result == result
      assert state.search_task_ref == nil
    end

    test ":DOWN message with matching ref transitions to :error", %{
      conn: conn,
      project_id: project_id
    } do
      fake_ref = Process.monitor(self())
      Process.demonitor(fake_ref, [:flush])

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/search"

      :sys.replace_state(view.pid, fn state ->
        assigns = Map.put(state.socket.assigns, :search_task_ref, fake_ref)
        assigns = Map.put(assigns, :search_status, :searching)
        %{state | socket: %{state.socket | assigns: assigns}}
      end)

      send(view.pid, {:DOWN, fake_ref, :process, self(), :boom})
      :sys.get_state(view.pid)

      state = state_assigns(view)
      assert state.search_status == :error
      assert state.search_task_ref == nil
    end

    test "result arriving after tab switch still updates shell assigns", %{
      conn: conn,
      project_id: project_id
    } do
      fake_ref = Process.monitor(self())
      Process.demonitor(fake_ref, [:flush])

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/search"

      :sys.replace_state(view.pid, fn state ->
        assigns = Map.put(state.socket.assigns, :search_task_ref, fake_ref)
        assigns = Map.put(assigns, :search_status, :searching)
        %{state | socket: %{state.socket | assigns: assigns}}
      end)

      view
      |> element(~s|a[href="/projects/#{project_id}/health"][data-phx-link="patch"]|)
      |> render_click()

      result = %{
        project_id: project_id,
        query: "late",
        session_id: nil,
        memory: %{semantic: "cached", episodic: nil, procedural: nil},
        touched_node_ids: ["late-1"]
      }

      send(view.pid, {fake_ref, {:ok, result}})
      :sys.get_state(view.pid)

      state = state_assigns(view)
      assert state.search_status == :completed
      assert state.search_result == result

      view
      |> element(~s|a[href="/projects/#{project_id}/search"][data-phx-link="patch"]|)
      |> render_click()

      rendered = render(view)
      assert rendered =~ "cached"
      assert rendered =~ "late-1"
    end
  end

  describe "graph tab" do
    test "navigating to /graph renders the graph tab via GraphTabComponent", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)

      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/graph"

      assert html =~ "Force"
      assert html =~ "Subgoal Tree"
      assert html =~ "Provenance"
      refute html =~ "Layered"
      refute html =~ "Tab &quot;graph&quot; not implemented yet."
    end

    test "?node=abc sets :selected_node_id and calls monitor_graph with node_id", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn attrs ->
        send(test_pid, {:monitor_graph_called, attrs})
        empty_graph_view(:focused)
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph?node=abc"

      state = state_assigns(view)
      assert state.selected_node_id == "abc"
      assert_received {:monitor_graph_called, attrs}
      assert attrs.view in [:project, :focused]

      if attrs.view == :focused do
        assert attrs.node_id == "abc"
      end
    end

    test "select_graph_node updates :selected_node_id", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      render_hook(view, "select_graph_node", %{"id" => "my-node"})

      assert state_assigns(view).selected_node_id == "my-node"
    end

    test "select_graph_node in :force mode pushes lightweight highlight, not update_graph", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      render_hook(view, "select_graph_node", %{"id" => "my-node"})

      assert_push_event view, "select_graph_node_highlight", %{id: "my-node"}
    end

    test "set_graph_layout updates :graph_layout_mode and calls monitor_graph with mapping", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn attrs ->
        send(test_pid, {:monitor_graph_called, attrs})
        empty_graph_view(:project)
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      send(view.pid, {:graph, :select_layout, :force})
      :sys.get_state(view.pid)

      assert state_assigns(view).graph_layout_mode == :force
      assert_received {:monitor_graph_called, %{view: :project, layout_mode: :force}}
    end

    test "set_graph_layout :provenance switches to :query view", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn attrs ->
        send(test_pid, {:monitor_graph_called, attrs})
        empty_graph_view(:query)
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      send(view.pid, {:graph, :select_layout, :provenance})
      :sys.get_state(view.pid)

      assert state_assigns(view).graph_layout_mode == :provenance
      assert_received {:monitor_graph_called, %{view: :query}}
    end

    test "provenance layout passes touched_node_ids from :search_result to monitor_graph", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn attrs ->
        send(test_pid, {:monitor_graph_called, attrs})
        empty_graph_view(:query)
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      :sys.replace_state(view.pid, fn state ->
        assigns =
          Map.put(state.socket.assigns, :search_result, %{
            project_id: project_id,
            query: "hello",
            session_id: nil,
            memory: %{semantic: nil, episodic: nil, procedural: nil},
            touched_node_ids: ["n-a", "n-b", "n-c"]
          })

        %{state | socket: %{state.socket | assigns: assigns}}
      end)

      send(view.pid, {:graph, :select_layout, :provenance})
      :sys.get_state(view.pid)

      assert_received {:monitor_graph_called,
                       %{view: :query, touched_node_ids: ["n-a", "n-b", "n-c"]}}
    end

    test "set_graph_layout :subgoal_tree switches to :focused view", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn attrs ->
        send(test_pid, {:monitor_graph_called, attrs})
        empty_graph_view(:focused)
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      send(view.pid, {:graph, :select_layout, :subgoal_tree})
      :sys.get_state(view.pid)

      assert state_assigns(view).graph_layout_mode == :subgoal_tree
      assert_received {:monitor_graph_called, %{view: :focused}}
    end

    test "expand_cluster calls Memory.expand_cluster/1 and pushes cluster_expanded", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)

      stub(Memory, :expand_cluster, fn %{project_id: ^project_id, cluster_id: "cluster-1"} ->
        {:ok, %{cluster_id: "cluster-1", nodes: [], edges: [], layout_mode: :force}}
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      render_hook(view, "expand_cluster", %{"cluster_id" => "cluster-1"})

      assert state_assigns(view).expanded_cluster_id == "cluster-1"

      assert_push_event view, "cluster_expanded", %{cluster_id: "cluster-1"}
    end

    test "collapse_cluster pushes cluster_collapsed", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      render_hook(view, "collapse_cluster", %{"cluster_id" => "c-x"})

      assert state_assigns(view).expanded_cluster_id == nil
      assert_push_event view, "cluster_collapsed", %{cluster_id: "c-x"}
    end

    test "select_graph_node while a cluster is expanded does not rebuild the graph", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn _ ->
        send(test_pid, :monitor_graph_called)
        empty_graph_view(:project)
      end)

      stub(Memory, :expand_cluster, fn %{project_id: ^project_id, cluster_id: "cluster-1"} ->
        {:ok, %{cluster_id: "cluster-1", nodes: [], edges: [], layout_mode: :force}}
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/graph"

      render_hook(view, "expand_cluster", %{"cluster_id" => "cluster-1"})
      assert_push_event view, "cluster_expanded", %{cluster_id: "cluster-1"}
      assert state_assigns(view).expanded_cluster_id == "cluster-1"

      flush_monitor_graph_messages()

      render_hook(view, "select_graph_node", %{"id" => "child-node"})

      assert state_assigns(view).selected_node_id == "child-node"
      assert state_assigns(view).expanded_cluster_id == "cluster-1"
      assert_push_event view, "select_graph_node_highlight", %{id: "child-node"}
      refute_received :monitor_graph_called
    end
  end

  defp flush_monitor_graph_messages do
    receive do
      :monitor_graph_called -> flush_monitor_graph_messages()
    after
      0 -> :ok
    end
  end

  describe "health tab" do
    test "first visit to /health calls Memory.inspector_data/1 once", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :inspector_data, fn ^project_id ->
        send(test_pid, {:inspector_data_called, project_id})
        {:ok, %{}}
      end)

      {:ok, _view, _html} = live conn, ~p"/projects/#{project_id}/health"

      assert_received {:inspector_data_called, ^project_id}
    end

    test "second visit reuses cached node_map and does not re-call inspector_data", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)

      stub(Memory, :inspector_data, fn ^project_id ->
        send(test_pid, :inspector_data_called)
        {:ok, %{}}
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/health"
      drain_inbox(:inspector_data_called)
      assert state_assigns(view).inspector_loaded_at

      view
      |> element(~s|a[href="/projects/#{project_id}/memories"][data-phx-link="patch"]|)
      |> render_click()

      view
      |> element(~s|a[href="/projects/#{project_id}/health"][data-phx-link="patch"]|)
      |> render_click()

      refute_received :inspector_data_called
    end

    test ":changeset_applied invalidates the inspector cache so next visit re-fetches", %{
      conn: conn,
      project_id: project_id
    } do
      test_pid = self()

      stub(Memory, :monitor_graph, fn _ -> empty_graph_view(:project) end)

      stub(Memory, :inspector_data, fn ^project_id ->
        send(test_pid, :inspector_data_called)
        {:ok, %{}}
      end)

      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/health"
      drain_inbox(:inspector_data_called)

      view
      |> element(~s|a[href="/projects/#{project_id}/memories"][data-phx-link="patch"]|)
      |> render_click()

      send(
        view.pid,
        {:memory_event,
         %SessionMonitorEvent{
           type: :changeset_applied,
           project_id: project_id,
           repo_id: "project:#{project_id}",
           timestamp: DateTime.utc_now(),
           summary: %{node_count: 1, link_count: 1}
         }}
      )

      :sys.get_state(view.pid)
      assert state_assigns(view).inspector_loaded_at == nil

      view
      |> element(~s|a[href="/projects/#{project_id}/health"][data-phx-link="patch"]|)
      |> render_click()

      assert_received :inspector_data_called
    end

    test ":changeset_applied while on health tab re-fetches inspector data immediately", %{
      conn: conn,
      project_id: project_id
    } do
      assert_health_refetch_on_event(conn, project_id, :changeset_applied)
    end

    test ":decay_completed while on health tab re-fetches inspector data immediately", %{
      conn: conn,
      project_id: project_id
    } do
      assert_health_refetch_on_event(conn, project_id, :decay_completed)
    end

    test ":validation_completed while on health tab re-fetches inspector data immediately", %{
      conn: conn,
      project_id: project_id
    } do
      assert_health_refetch_on_event(conn, project_id, :validation_completed)
    end

    test "quality cards render the shell's :quality assign values", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :inspector_data, fn ^project_id -> {:ok, %{}} end)

      stub(Memory, :project_monitor_snapshot, fn ^project_id ->
        Map.put(empty_snapshot(), :quality, %{
          total_nodes: 15,
          total_edges: 9,
          orphan_count: 2,
          avg_confidence: 0.777,
          last_decay_at: nil,
          last_consolidation_at: nil,
          last_validation_at: nil
        })
      end)

      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/health"

      assert html =~ "Total Nodes"
      assert html =~ "15"
      assert html =~ "Total Edges"
      assert html =~ "9"
      assert html =~ "Orphans"
      assert html =~ "2"
      assert html =~ "Avg Confidence"
      assert html =~ "77.7%"
    end
  end

  describe "events tab" do
    test "navigating to /events renders the events tab component", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/events"

      refute html =~ ~s|Tab &quot;events&quot; not implemented yet.|
      assert html =~ "All"
      assert html =~ "Maintenance"
      assert html =~ "Recalls"
    end

    test "?filter=sessions on mount sets events_filter_mode to :sessions", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/events?filter=sessions"

      assert state_assigns(view).events_filter_mode == :sessions
    end

    test "?filter=sessions&session_id=abc sets both assigns", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} =
        live conn, ~p"/projects/#{project_id}/events?filter=sessions&session_id=abc"

      state = state_assigns(view)
      assert state.events_filter_mode == :sessions
      assert state.events_session_filter == "abc"
    end

    test "{:events, :set_filter, :maintenance} updates shell and patches URL", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/events"

      send(view.pid, {:events, :set_filter, :maintenance})

      assert_patch view, ~p"/projects/#{project_id}/events?filter=maintenance"
      assert state_assigns(view).events_filter_mode == :maintenance
    end

    test "{:events, :toggle_event, key} flips expanded id", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/events"

      send(view.pid, {:events, :toggle_event, "abc"})
      :sys.get_state(view.pid)
      assert state_assigns(view).events_expanded_id == "abc"

      send(view.pid, {:events, :toggle_event, "abc"})
      :sys.get_state(view.pid)
      assert state_assigns(view).events_expanded_id == nil
    end

    test "{:events, :filter_session, id} sets session filter and patches URL", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/events"

      send(view.pid, {:events, :filter_session, "sess-zz"})

      assert_patch view, ~p"/projects/#{project_id}/events?filter=sessions&session_id=sess-zz"
      state = state_assigns(view)
      assert state.events_filter_mode == :sessions
      assert state.events_session_filter == "sess-zz"
    end

    test "memory_event while on events tab prepends the new event into the timeline", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, html} = live conn, ~p"/projects/#{project_id}/events"
      refute html =~ "changeset_applied"

      event = %SessionMonitorEvent{
        type: :changeset_applied,
        project_id: project_id,
        repo_id: "project:#{project_id}",
        timestamp: DateTime.utc_now(),
        summary: %{node_count: 7, link_count: 2}
      }

      Phoenix.PubSub.broadcast(
        Gingko.PubSub,
        Memory.project_monitor_topic(project_id),
        {:memory_event, event}
      )

      eventually(fn ->
        rendered = render(view)
        assert rendered =~ "changeset_applied"
        assert rendered =~ "7 nodes, 2 links"
      end)
    end
  end

  describe "summaries tab" do
    test "Regenerate click in the State panel surfaces a flash on the parent LiveView", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/summaries"

      view
      |> element(~s|button[phx-value-scope="state"]|)
      |> render_click()

      _ = :sys.get_state(view.pid)

      assert Phoenix.Flash.get(state_assigns(view).flash, :info) ==
               "Principal state regeneration enqueued."
    end
  end

  describe "misc handle_info" do
    test ":projects_changed is a no-op", %{conn: conn, project_id: project_id} do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      send(view.pid, :projects_changed)
      assert Process.alive?(view.pid)
      assert render(view) =~ project_id
    end

    test "unknown memory_event payload sets connection_status to :degraded", %{
      conn: conn,
      project_id: project_id
    } do
      {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/memories"

      send(view.pid, {:memory_event, %{type: :bogus}})

      assert render(view) =~ "degraded"
    end

    test "mount renders degraded status when snapshot comes back degraded: true", %{
      conn: conn,
      project_id: project_id
    } do
      stub(Memory, :project_monitor_snapshot, fn ^project_id ->
        Map.put(empty_snapshot(), :degraded, true)
      end)

      {:ok, _view, html} = live conn, ~p"/projects/#{project_id}/memories"

      assert html =~ "degraded"
    end
  end

  defp empty_snapshot do
    %{
      active_sessions: [],
      recent_events: [],
      counters: %{active_sessions: 0, recent_commits: 0, recent_recalls: 0},
      quality: %{
        total_nodes: 0,
        total_edges: 0,
        orphan_count: 0,
        avg_confidence: nil,
        last_decay_at: nil,
        last_consolidation_at: nil,
        last_validation_at: nil
      }
    }
  end

  defp empty_graph_view(mode) do
    %{
      mode: mode,
      title: "Graph",
      selection: %{node_id: nil, session_id: nil},
      nodes: [],
      edges: [],
      expandable_nodes: [],
      stats: %{node_count: 0, edge_count: 0, type_counts: %{}},
      layout_mode: :force
    }
  end

  defp state_assigns(view) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assigns
  end

  defp drain_inbox(msg) do
    receive do
      ^msg -> drain_inbox(msg)
    after
      0 -> :ok
    end
  end

  defp eventually(fun, retries \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, retries - 1)
  end

  defp assert_health_refetch_on_event(conn, project_id, event_type) do
    first_map = %{
      "node-a" => %Semantic{
        id: "node-a",
        proposition: "first-orphan",
        confidence: 0.9,
        links: Edge.empty_links()
      }
    }

    second_map = %{
      "node-b" => %Semantic{
        id: "node-b",
        proposition: "second-orphan",
        confidence: 0.9,
        links: Edge.empty_links()
      }
    }

    {:ok, call_agent} = Agent.start_link(fn -> 0 end)

    stub(Memory, :inspector_data, fn ^project_id ->
      n = Agent.get_and_update(call_agent, fn n -> {n, n + 1} end)
      if n < 2, do: {:ok, first_map}, else: {:ok, second_map}
    end)

    {:ok, view, _html} = live conn, ~p"/projects/#{project_id}/health"

    initial = render(view)
    assert initial =~ "first-orphan"
    refute initial =~ "second-orphan"
    calls_after_mount = Agent.get(call_agent, & &1)

    send(
      view.pid,
      {:memory_event,
       %SessionMonitorEvent{
         type: event_type,
         project_id: project_id,
         repo_id: "project:#{project_id}",
         timestamp: DateTime.utc_now(),
         summary: %{}
       }}
    )

    :sys.get_state(view.pid)

    rendered = render(view)
    refute rendered =~ "first-orphan"
    assert rendered =~ "second-orphan"
    assert Agent.get(call_agent, & &1) == calls_after_mount + 1
  end
end
