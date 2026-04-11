defmodule GingkoWeb.ProjectLive.GraphViewTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Gingko.Memory
  alias GingkoWeb.ProjectLive.GraphView

  setup :set_mimic_global

  setup do
    Mimic.copy(Gingko.Memory)
    :ok
  end

  describe "empty_graph_view/1" do
    test "returns the Project-graph shape for :project" do
      assert %{
               mode: :project,
               title: "Project Graph",
               selection: %{node_id: nil, session_id: nil},
               nodes: [],
               edges: [],
               expandable_nodes: [],
               stats: %{node_count: 0, edge_count: 0, type_counts: %{}},
               layout_mode: :force
             } = GraphView.empty_graph_view(:project)
    end

    test "returns the generic shape for :focused" do
      assert %{
               mode: :focused,
               title: "Graph",
               selection: %{node_id: nil, session_id: nil},
               nodes: [],
               edges: [],
               expandable_nodes: [],
               stats: %{node_count: 0, edge_count: 0, type_counts: %{}},
               layout_mode: :force
             } = GraphView.empty_graph_view(:focused)
    end

    test "returns the generic shape for :query" do
      assert %{mode: :query, title: "Graph"} = GraphView.empty_graph_view(:query)
    end
  end

  describe "graph_view_params/1" do
    test "force layout emits view=:project with selected+expanded node ids" do
      assigns = %{
        project_id: "p-1",
        graph_layout_mode: :force,
        selected_node_id: "n-1",
        expanded_node_ids: MapSet.new(["x"])
      }

      assert %{
               project_id: "p-1",
               view: :project,
               layout_mode: :force,
               node_id: "n-1",
               expanded_node_ids: %MapSet{}
             } = GraphView.graph_view_params(assigns)
    end

    test "subgoal_tree layout emits view=:focused" do
      assigns = %{
        project_id: "p-3",
        graph_layout_mode: :subgoal_tree,
        selected_node_id: "root",
        expanded_node_ids: MapSet.new()
      }

      params = GraphView.graph_view_params(assigns)
      assert params.view == :focused
      assert params.node_id == "root"
      refute Map.has_key?(params, :layout_mode)
    end

    test "provenance layout emits view=:query and extracts touched_node_ids" do
      assigns = %{
        project_id: "p-4",
        graph_layout_mode: :provenance,
        search_result: %{touched_node_ids: ["a", "b"]},
        expanded_node_ids: MapSet.new()
      }

      assert %{
               project_id: "p-4",
               view: :query,
               touched_node_ids: ["a", "b"]
             } = GraphView.graph_view_params(assigns)
    end

    test "provenance layout with nil search_result returns empty touched_node_ids" do
      assigns = %{
        project_id: "p-5",
        graph_layout_mode: :provenance,
        search_result: nil,
        expanded_node_ids: MapSet.new()
      }

      assert %{touched_node_ids: []} = GraphView.graph_view_params(assigns)
    end
  end

  describe "refresh_graph_view/1" do
    test "populates socket.assigns.graph_view from Memory.monitor_graph/1" do
      returned = GraphView.empty_graph_view(:project)
      stub(Memory, :monitor_graph, fn _params -> returned end)

      socket = fake_socket(%{graph_layout_mode: :force})

      updated = GraphView.refresh_graph_view(socket)

      assert updated.assigns.graph_view == returned
    end
  end

  describe "maybe_refresh_graph_view/2" do
    test "skips (does not call Memory) when active_tab != \"graph\"" do
      stub(Memory, :monitor_graph, fn _ ->
        flunk("Memory.monitor_graph/1 should not be called when tab is not \"graph\"")
      end)

      before = fake_socket(%{graph_layout_mode: :force, graph_view: :unchanged})
      after_socket = GraphView.maybe_refresh_graph_view(before, "memories")

      assert after_socket.assigns.graph_view == :unchanged
    end

    test "refreshes the graph when active_tab is \"graph\"" do
      returned = GraphView.empty_graph_view(:project)
      stub(Memory, :monitor_graph, fn _ -> returned end)

      socket = fake_socket(%{graph_layout_mode: :force})
      updated = GraphView.maybe_refresh_graph_view(socket, "graph")

      assert updated.assigns.graph_view == returned
    end
  end

  describe "maybe_apply_graph_deep_link/3" do
    test "assigns selected_node_id when tab is graph and params include :node" do
      socket = fake_socket(%{selected_node_id: nil})
      updated = GraphView.maybe_apply_graph_deep_link(socket, "graph", %{node: "n-42"})

      assert updated.assigns.selected_node_id == "n-42"
    end

    test "is a no-op when tab != graph" do
      socket = fake_socket(%{selected_node_id: "prior"})
      updated = GraphView.maybe_apply_graph_deep_link(socket, "memories", %{node: "n-42"})

      assert updated.assigns.selected_node_id == "prior"
    end

    test "is a no-op when params have no :node key" do
      socket = fake_socket(%{selected_node_id: "prior"})
      updated = GraphView.maybe_apply_graph_deep_link(socket, "graph", %{})

      assert updated.assigns.selected_node_id == "prior"
    end
  end

  defp fake_socket(overrides) do
    assigns =
      Map.merge(
        %{
          project_id: "p-test",
          graph_layout_mode: :force,
          selected_node_id: nil,
          expanded_node_ids: MapSet.new(),
          search_result: nil,
          graph_view: nil,
          __changed__: %{}
        },
        overrides
      )

    %Phoenix.LiveView.Socket{
      assigns: assigns,
      endpoint: GingkoWeb.Endpoint,
      transport_pid: nil
    }
  end
end
