defmodule GingkoWeb.ProjectLive.GraphTabComponent do
  @moduledoc """
  Graph tab for `GingkoWeb.ProjectLive`.

  Composes `GraphViewportComponent` (Cytoscape canvas) and
  `NodeInspectorComponent` (selection side panel) under a layout-mode
  switcher. Three layout modes collapse the old Project Monitor's project/
  session graph views and the old Inspector's Subgoal Tree / Provenance
  tabs into a single affordance:

  - `:force`        -> `Memory.monitor_graph/1` `view: :project, layout_mode: :force`
  - `:subgoal_tree` -> `Memory.monitor_graph/1` `view: :focused`
  - `:provenance`   -> `Memory.monitor_graph/1` `view: :query`

  The shell owns `:graph_layout_mode`, `:graph_view`, `:selected_node_id`,
  `:expanded_node_ids`, and `:expanded_cluster_id`. This component emits
  `{:graph, :select_layout, layout}` intents on button clicks; state flows
  back in through props only.
  """

  use GingkoWeb, :live_component

  alias GingkoWeb.ProjectLive.GraphViewportComponent
  alias GingkoWeb.ProjectLive.NodeInspectorComponent

  @layouts [
    {:force, "Force"},
    {:subgoal_tree, "Subgoal Tree"},
    {:provenance, "Provenance"}
  ]

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :layouts, @layouts)

    ~H"""
    <section class="space-y-4">
      <div class="rounded-2xl border border-base-300 bg-base-100 p-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="join" role="group" aria-label="Graph layout">
            <button
              :for={{layout, label} <- @layouts}
              type="button"
              phx-click="set_graph_layout"
              phx-value-layout={layout}
              phx-target={@myself}
              aria-pressed={to_string(@layout_mode == layout)}
              class={layout_button_class(@layout_mode == layout)}
            >
              {label}
            </button>
          </div>

          <div class="flex flex-wrap gap-2 text-xs text-base-content/70">
            <span class="rounded-full border border-base-300 px-3 py-1">
              Nodes: {Map.get(@graph.stats, :node_count, 0)}
            </span>
            <span class="rounded-full border border-base-300 px-3 py-1">
              Edges: {Map.get(@graph.stats, :edge_count, 0)}
            </span>
          </div>
        </div>
      </div>

      <div
        :if={@layout_mode == :subgoal_tree and is_nil(@selected_node_id)}
        class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-6 text-sm text-base-content/70"
      >
        Select a node in the project view first to explore its subgoal tree.
      </div>

      <div
        :if={@layout_mode == :provenance and Enum.empty?(@graph.nodes)}
        class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-6 text-sm text-base-content/70"
      >
        Run a query in the Search tab to populate provenance.
      </div>

      <.live_component module={GraphViewportComponent} id="graph-viewport" graph={@graph} />

      <.live_component module={NodeInspectorComponent} id="graph-node-inspector" graph={@graph} />
    </section>
    """
  end

  @impl true
  def handle_event("set_graph_layout", %{"layout" => layout}, socket) do
    send(self(), {:graph, :select_layout, parse_layout(layout)})
    {:noreply, socket}
  end

  defp layout_button_class(true), do: "btn join-item btn-primary"
  defp layout_button_class(false), do: "btn join-item btn-ghost"

  defp parse_layout("force"), do: :force
  defp parse_layout("subgoal_tree"), do: :subgoal_tree
  defp parse_layout("provenance"), do: :provenance
  defp parse_layout(_), do: :force
end
