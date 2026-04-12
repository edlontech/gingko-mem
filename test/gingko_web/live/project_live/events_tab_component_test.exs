defmodule GingkoWeb.ProjectLive.EventsTabComponentTest do
  use GingkoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Gingko.Memory.SessionMonitorEvent
  alias GingkoWeb.ProjectLive.EventsTabComponent

  defp event(type, attrs \\ []) do
    attrs = Map.new(attrs)

    %SessionMonitorEvent{
      type: type,
      project_id: "p-1",
      repo_id: "project:p-1",
      timestamp: Map.get(attrs, :timestamp, ~U[2026-04-21 12:00:00Z]),
      session_id: Map.get(attrs, :session_id),
      node_ids: Map.get(attrs, :node_ids, []),
      summary: Map.get(attrs, :summary, %{})
    }
  end

  defp active_session(session_id, attrs) do
    attrs = Map.new(attrs)

    %{
      session_id: session_id,
      state: Map.get(attrs, :state, :collecting),
      latest_activity_at: Map.get(attrs, :latest_activity_at, ~U[2026-04-21 12:00:00Z]),
      summary: Map.get(attrs, :summary, %{goal: "do something"})
    }
  end

  defp past_session(session_id, attrs) do
    attrs = Map.new(attrs)

    %Gingko.Projects.Session{
      session_id: session_id,
      status: Map.get(attrs, :status, "finished"),
      goal: Map.get(attrs, :goal, "past goal"),
      node_ids: [],
      node_count: Map.get(attrs, :node_count, 0),
      trajectory_count: Map.get(attrs, :trajectory_count, 0),
      started_at: Map.get(attrs, :started_at, ~U[2026-04-20 10:00:00Z]),
      finished_at: Map.get(attrs, :finished_at, ~U[2026-04-20 11:00:00Z]),
      updated_at: Map.get(attrs, :updated_at, ~U[2026-04-20 11:00:00Z])
    }
  end

  defp render_events(assigns) do
    defaults = %{
      id: "events-tab",
      project_id: "p-1",
      events: [],
      active_sessions: [],
      past_sessions: [],
      filter_mode: :all,
      session_id_filter: nil,
      expanded_event_id: nil
    }

    render_component(EventsTabComponent, Map.merge(defaults, assigns))
  end

  describe "filter bar" do
    test "renders all four filter buttons" do
      html = render_events(%{})

      assert html =~ "All"
      assert html =~ "Sessions"
      assert html =~ "Maintenance"
      assert html =~ "Recalls"
    end

    test "active button has the active modifier class" do
      html = render_events(%{filter_mode: :maintenance})

      assert html =~ ~r|phx-value-mode="maintenance"[^>]*btn-active|s
      assert html =~ ~r|phx-value-mode="maintenance"[^>]*aria-pressed="true"|s
      assert html =~ ~r|phx-value-mode="all"[^>]*aria-pressed="false"|s
      assert html =~ ~r|phx-value-mode="sessions"[^>]*aria-pressed="false"|s
      assert html =~ ~r|phx-value-mode="recalls"[^>]*aria-pressed="false"|s
      assert html =~ ~s|role="group"|
      assert html =~ ~s|aria-label="Event filter"|
    end
  end

  describe ":all filter" do
    test "renders every event passed in" do
      events = [
        event(:recall_executed,
          summary: %{query_snippet: "who", result_count: 3, search_mode: :hybrid}
        ),
        event(:changeset_applied, summary: %{node_count: 2, link_count: 1}),
        event(:decay_completed, summary: %{})
      ]

      html = render_events(%{events: events, filter_mode: :all})

      assert html =~ "recall_executed"
      assert html =~ "changeset_applied"
      assert html =~ "decay_completed"
    end
  end

  describe ":maintenance filter" do
    test "keeps only maintenance events" do
      events = [
        event(:recall_executed, summary: %{query_snippet: "q", result_count: 1}),
        event(:decay_completed),
        event(:consolidation_completed),
        event(:validation_completed),
        event(:nodes_deleted, summary: %{count: 2}),
        event(:session_started, session_id: "s")
      ]

      html = render_events(%{events: events, filter_mode: :maintenance})

      assert html =~ "decay_completed"
      assert html =~ "consolidation_completed"
      assert html =~ "validation_completed"
      assert html =~ "nodes_deleted"
      refute html =~ "recall_executed"
      refute html =~ "session_started"
    end
  end

  describe ":recalls filter" do
    test "keeps only recall events" do
      events = [
        event(:recall_executed, summary: %{query_snippet: "ok", result_count: 2}),
        event(:recall_failed, summary: %{query_snippet: "boom", reason: "timeout"}),
        event(:changeset_applied, summary: %{node_count: 1})
      ]

      html = render_events(%{events: events, filter_mode: :recalls})

      assert html =~ "recall_executed"
      assert html =~ "recall_failed"
      refute html =~ "changeset_applied"
    end
  end

  describe ":sessions filter" do
    test "renders one row per unique session_id and shows state + activity time" do
      active = [active_session("sess-active", state: :collecting)]
      past = [past_session("sess-past-1", goal: "past goal")]

      events = [
        event(:step_appended, session_id: "sess-active", summary: %{step_index: 1}),
        event(:session_committed, session_id: "sess-past-1", summary: %{node_count: 3})
      ]

      html =
        render_events(%{
          events: events,
          active_sessions: active,
          past_sessions: past,
          filter_mode: :sessions
        })

      assert html =~ "sess-active"
      assert html =~ "sess-past-1"
      assert html =~ "collecting"
    end

    test "clicking a session row dispatches {:events, :filter_session, id}" do
      test_pid = self()
      name = :"sessions_harness_#{System.unique_integer([:positive])}"
      Process.register(test_pid, name)

      on_exit(fn ->
        if Process.whereis(name) == test_pid, do: Process.unregister(name)
      end)

      conn = Plug.Test.init_test_session(build_conn(), %{"test_pid_name" => Atom.to_string(name)})

      {:ok, view, _html} = live_isolated(conn, __MODULE__.SessionsHarness)

      view
      |> element(~s|button[phx-value-session_id="sess-xyz"]|)
      |> render_click()

      :sys.get_state(view.pid)
      assert_received {:shell_message, {:events, :filter_session, "sess-xyz"}}
    end
  end

  describe "regular event expand/collapse" do
    test "collapsed row shows header but not summary key/value pairs" do
      ev =
        event(:recall_executed,
          summary: %{query_snippet: "hi", result_count: 2, search_mode: :hybrid}
        )

      html = render_events(%{events: [ev], filter_mode: :all})

      refute html =~ "query_snippet:"
    end

    test "expanded row shows summary dl with key/values" do
      ev =
        event(:recall_executed,
          summary: %{query_snippet: "hi", result_count: 2, search_mode: :hybrid}
        )

      key = SessionMonitorEvent.event_key(ev)

      html = render_events(%{events: [ev], filter_mode: :all, expanded_event_id: key})

      assert html =~ "query_snippet"
      assert html =~ "result_count"
      assert html =~ "search_mode"
    end
  end

  describe "session row expand" do
    test "expanding a session row shows lifecycle events for that session" do
      active = [active_session("sess-a", state: :collecting)]

      events = [
        event(:session_started, session_id: "sess-a", summary: %{}),
        event(:step_appended, session_id: "sess-a", summary: %{step_index: 1}),
        event(:step_appended, session_id: "sess-b", summary: %{step_index: 9})
      ]

      html =
        render_events(%{
          events: events,
          active_sessions: active,
          filter_mode: :sessions,
          expanded_event_id: "session:sess-a"
        })

      assert html =~ "session_started"
      assert html =~ "step_appended"
      refute html =~ "step 9"
    end
  end

  describe "session_id_filter auto-expands" do
    test "filter_mode=:sessions with session_id_filter auto-expands that session row" do
      active = [active_session("sess-auto", state: :collecting)]

      events = [
        event(:session_started, session_id: "sess-auto", summary: %{}),
        event(:step_appended, session_id: "sess-auto", summary: %{step_index: 7})
      ]

      html =
        render_events(%{
          events: events,
          active_sessions: active,
          filter_mode: :sessions,
          session_id_filter: "sess-auto"
        })

      assert html =~ "session_started"
      assert html =~ "step 7"
    end
  end

  defmodule SessionsHarness do
    use GingkoWeb, :live_view

    alias Gingko.Memory.SessionMonitorEvent

    @impl true
    def mount(_params, session, socket) do
      test_pid =
        session
        |> Map.get("test_pid_name")
        |> String.to_existing_atom()
        |> Process.whereis()

      events = [
        %SessionMonitorEvent{
          type: :step_appended,
          project_id: "p-1",
          repo_id: "project:p-1",
          timestamp: ~U[2026-04-21 12:00:00Z],
          session_id: "sess-xyz",
          summary: %{step_index: 1}
        }
      ]

      active = [
        %{
          session_id: "sess-xyz",
          state: :collecting,
          latest_activity_at: ~U[2026-04-21 12:00:00Z],
          summary: %{goal: "x"}
        }
      ]

      {:ok,
       socket
       |> Phoenix.Component.assign(:test_pid, test_pid)
       |> Phoenix.Component.assign(:events, events)
       |> Phoenix.Component.assign(:active_sessions, active)}
    end

    @impl true
    def handle_info({:events, _action, _payload} = msg, socket) do
      send(socket.assigns.test_pid, {:shell_message, msg})
      {:noreply, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={GingkoWeb.ProjectLive.EventsTabComponent}
          id="events-tab"
          project_id="p-1"
          events={@events}
          active_sessions={@active_sessions}
          past_sessions={[]}
          filter_mode={:sessions}
          session_id_filter={nil}
          expanded_event_id={nil}
        />
      </div>
      """
    end
  end
end
