defmodule GingkoWeb.ProjectLive.GraphTabComponentTest do
  use GingkoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GingkoWeb.ProjectLive.GraphTabComponent

  describe "layout switcher" do
    test "renders all three layout-mode buttons" do
      html =
        render_component(GraphTabComponent,
          id: "graph-tab",
          project_id: "p-1",
          graph: empty_graph(:project, :force),
          layout_mode: :force,
          selected_node_id: nil
        )

      assert html =~ "Force"
      assert html =~ "Subgoal Tree"
      assert html =~ "Provenance"
      refute html =~ "Layered"

      assert html =~ ~s(role="group")
      assert html =~ ~s(aria-label="Graph layout")

      assert Regex.match?(
               ~r/phx-value-layout="force"[^>]*aria-pressed="true"/s,
               html
             )

      for layout <- ~w(subgoal_tree provenance) do
        assert Regex.match?(
                 ~r/phx-value-layout="#{layout}"[^>]*aria-pressed="false"/s,
                 html
               )
      end
    end

    test "marks the active layout button with btn-primary" do
      html =
        render_component(GraphTabComponent,
          id: "graph-tab",
          project_id: "p-1",
          graph: empty_graph(:focused, :force),
          layout_mode: :subgoal_tree,
          selected_node_id: nil
        )

      assert html =~ ~s(phx-value-layout="subgoal_tree")

      assert Regex.match?(
               ~r/phx-value-layout="subgoal_tree"[^>]*class="[^"]*btn-primary/s,
               html
             )

      refute Regex.match?(
               ~r/phx-value-layout="force"[^>]*class="[^"]*btn-primary/s,
               html
             )
    end
  end

  describe "click layout button" do
    test "dispatches {:graph, :select_layout, :force} to parent LiveView" do
      test_pid_str = self() |> :erlang.pid_to_list() |> List.to_string()

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          GingkoWeb.ProjectLive.GraphTabComponentTest.Harness,
          session: %{"test_pid" => test_pid_str}
        )

      view
      |> element(~s|button[phx-value-layout="force"]|)
      |> render_click()

      assert_receive {:graph, :select_layout, :force}
    end

    test "dispatches :subgoal_tree for Subgoal Tree button" do
      test_pid_str = self() |> :erlang.pid_to_list() |> List.to_string()

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          GingkoWeb.ProjectLive.GraphTabComponentTest.Harness,
          session: %{"test_pid" => test_pid_str}
        )

      view
      |> element(~s|button[phx-value-layout="subgoal_tree"]|)
      |> render_click()

      assert_receive {:graph, :select_layout, :subgoal_tree}
    end

    test "dispatches :provenance for Provenance button" do
      test_pid_str = self() |> :erlang.pid_to_list() |> List.to_string()

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          GingkoWeb.ProjectLive.GraphTabComponentTest.Harness,
          session: %{"test_pid" => test_pid_str}
        )

      view
      |> element(~s|button[phx-value-layout="provenance"]|)
      |> render_click()

      assert_receive {:graph, :select_layout, :provenance}
    end
  end

  describe "empty graph state" do
    test "renders viewport empty-state text when no nodes" do
      html =
        render_component(GraphTabComponent,
          id: "graph-tab",
          project_id: "p-1",
          graph: empty_graph(:project, :force),
          layout_mode: :force,
          selected_node_id: nil
        )

      assert html =~ "No graph data for this view yet."
    end
  end

  describe "subgoal tree mode hint" do
    test "renders hint when no node selected" do
      html =
        render_component(GraphTabComponent,
          id: "graph-tab",
          project_id: "p-1",
          graph: empty_graph(:focused, :force),
          layout_mode: :subgoal_tree,
          selected_node_id: nil
        )

      assert html =~ "Select a node"
    end

    test "does not render hint when node selected" do
      html =
        render_component(GraphTabComponent,
          id: "graph-tab",
          project_id: "p-1",
          graph: empty_graph(:focused, :force),
          layout_mode: :subgoal_tree,
          selected_node_id: "node-1"
        )

      refute html =~ "Select a node in the project view first"
    end
  end

  describe "provenance mode hint" do
    test "renders hint when graph has no nodes" do
      html =
        render_component(GraphTabComponent,
          id: "graph-tab",
          project_id: "p-1",
          graph: empty_graph(:query, :force),
          layout_mode: :provenance,
          selected_node_id: nil
        )

      assert html =~ "Run a query"
    end
  end

  defp empty_graph(mode, layout_mode) do
    %{
      mode: mode,
      title: "Graph",
      selection: %{node_id: nil, session_id: nil},
      nodes: [],
      edges: [],
      expandable_nodes: [],
      stats: %{node_count: 0, edge_count: 0, type_counts: %{}},
      layout_mode: layout_mode
    }
  end

  defmodule Harness do
    use GingkoWeb, :live_view

    @impl true
    def mount(_params, %{"test_pid" => test_pid_str}, socket) do
      test_pid = test_pid_str |> String.to_charlist() |> :erlang.list_to_pid()

      {:ok,
       socket
       |> Phoenix.Component.assign(:test_pid, test_pid)
       |> Phoenix.Component.assign(:layout_mode, :force)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={GingkoWeb.ProjectLive.GraphTabComponent}
          id="graph-tab"
          project_id="p-1"
          graph={empty_graph()}
          layout_mode={@layout_mode}
          selected_node_id={nil}
        />
      </div>
      """
    end

    @impl true
    def handle_info({:graph, :select_layout, _layout} = msg, socket) do
      send(socket.assigns.test_pid, msg)
      {:noreply, socket}
    end

    defp empty_graph do
      %{
        mode: :project,
        title: "Project Graph",
        selection: %{node_id: nil, session_id: nil},
        nodes: [],
        edges: [],
        expandable_nodes: [],
        stats: %{node_count: 0, edge_count: 0, type_counts: %{}},
        layout_mode: :force
      }
    end
  end
end
