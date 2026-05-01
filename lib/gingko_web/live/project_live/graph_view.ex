defmodule GingkoWeb.ProjectLive.GraphView do
  @moduledoc """
  Graph lifecycle helpers extracted from `GingkoWeb.ProjectLive`.

  Functions here either operate on plain assign maps (`graph_view_params/1`,
  `empty_graph_view/1`) or take a `Phoenix.LiveView.Socket` and return an
  updated socket (`refresh_graph_view/1`, `maybe_refresh_graph_view/2`,
  `maybe_apply_graph_deep_link/3`). No PubSub, no direct I/O other than the
  delegated `Gingko.Memory.monitor_graph/1` call.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias Gingko.Memory
  alias GingkoWeb.ProjectLive.GraphViewportComponent

  @spec refresh_graph_view(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_graph_view(socket) do
    graph_view = Memory.monitor_graph(graph_view_params(socket.assigns))

    socket
    |> assign(:graph_view, graph_view)
    |> push_graph_update(graph_view)
  end

  @spec push_graph_update(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def push_graph_update(socket, graph_view) do
    if connected?(socket) do
      push_event(socket, "update_graph", GraphViewportComponent.graph_payload(graph_view))
    else
      socket
    end
  end

  @spec apply_node_selection(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def apply_node_selection(socket, node_id) do
    case socket.assigns.graph_layout_mode do
      mode when mode in [:subgoal_tree, :provenance] ->
        refresh_graph_view(socket)

      _ ->
        lightweight_selection_update(socket, node_id)
    end
  end

  defp lightweight_selection_update(socket, node_id) do
    graph_view = update_selection_classes(socket.assigns.graph_view, node_id)
    socket = assign(socket, :graph_view, graph_view)

    if connected?(socket) do
      push_event(socket, "select_graph_node_highlight", %{id: node_id})
    else
      socket
    end
  end

  defp update_selection_classes(%{nodes: nodes} = graph_view, selected_id) do
    updated_nodes =
      Enum.map(nodes, fn node ->
        classes =
          node
          |> Map.get(:classes, [])
          |> Enum.reject(&(&1 == "is-selected"))

        classes =
          if to_string(node.id) == to_string(selected_id) do
            ["is-selected" | classes]
          else
            classes
          end

        Map.put(node, :classes, classes)
      end)

    %{graph_view | nodes: updated_nodes}
  end

  defp update_selection_classes(graph_view, _selected_id), do: graph_view

  @spec graph_view_params(map()) :: map()
  def graph_view_params(%{graph_layout_mode: :force} = assigns) do
    %{
      project_id: assigns.project_id,
      view: :project,
      layout_mode: :force,
      node_id: assigns.selected_node_id,
      expanded_node_ids: assigns.expanded_node_ids
    }
  end

  def graph_view_params(%{graph_layout_mode: :subgoal_tree} = assigns) do
    %{
      project_id: assigns.project_id,
      view: :focused,
      node_id: assigns.selected_node_id,
      expanded_node_ids: assigns.expanded_node_ids
    }
  end

  def graph_view_params(%{graph_layout_mode: :provenance} = assigns) do
    %{
      project_id: assigns.project_id,
      view: :query,
      touched_node_ids: touched_node_ids(assigns.search_result),
      expanded_node_ids: assigns.expanded_node_ids
    }
  end

  @spec empty_graph_view(atom()) :: map()
  def empty_graph_view(:project) do
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

  def empty_graph_view(mode) do
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

  @spec maybe_refresh_graph_view(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_refresh_graph_view(socket, "graph"), do: refresh_graph_view(socket)
  def maybe_refresh_graph_view(socket, _tab), do: socket

  @spec maybe_apply_graph_deep_link(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_apply_graph_deep_link(socket, "graph", %{node: node_id}) when is_binary(node_id) do
    assign(socket, :selected_node_id, node_id)
  end

  def maybe_apply_graph_deep_link(socket, _tab, _params), do: socket

  defp touched_node_ids(%{touched_node_ids: list}) when is_list(list), do: list
  defp touched_node_ids(_), do: []
end
