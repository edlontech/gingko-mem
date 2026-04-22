defmodule GingkoWeb.ProjectLive.GraphViewportComponent do
  @moduledoc false

  use GingkoWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-role="graph-viewport" class="rounded-2xl border border-base-300 bg-base-100 p-4">
      <div class="flex items-center justify-between gap-3">
        <.header>{@graph.title}</.header>
        <p class="max-w-sm text-right text-xs text-base-content/70">
          Pan and zoom to explore. Click a node to refocus, then inspect connected neighbors.
        </p>
      </div>

      <div
        :if={Enum.empty?(@graph.nodes)}
        class="mt-3 rounded-xl border border-dashed border-base-300 p-6 text-sm text-base-content/70"
      >
        No graph data for this view yet.
      </div>

      <div
        :if={not Enum.empty?(@graph.nodes)}
        class="mt-4 rounded-2xl border border-base-300 bg-base-200/50 p-3"
      >
        <div class="relative">
          <div
            id={"graph-canvas-#{@id}"}
            phx-hook="GraphViewport"
            phx-update="ignore"
            data-role="graph-canvas"
            data-graph={Jason.encode!(graph_payload(@graph))}
            class="h-[24rem] w-full rounded-xl border border-base-300 bg-base-100 shadow-sm lg:h-[30rem]"
          >
          </div>

          <div
            data-role="graph-tooltip"
            class="pointer-events-auto absolute z-10 hidden max-w-[18rem] rounded-xl border border-base-300 bg-base-100 shadow-lg"
          >
            <div
              data-role="graph-tooltip-content"
              class="px-3 py-2 text-xs leading-5 text-base-content"
            >
            </div>
          </div>
        </div>
      </div>

      <div
        :if={not Enum.empty?(type_legend_entries(@graph.stats))}
        data-role="graph-legend"
        class="mt-4 rounded-xl border border-base-300 bg-base-100 px-3 py-3"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p class="text-xs uppercase tracking-wide text-base-content/70">Graph Guide</p>
            <p class="mt-1 text-xs text-base-content/70">
              Node colors show types. Click a chip to hide or show that type in the graph.
            </p>
          </div>

          <button type="button" data-role="graph-filter-reset" class="btn btn-ghost btn-xs">
            Show all
          </button>
        </div>

        <div class="mt-3 flex flex-wrap gap-2">
          <button
            :for={entry <- type_legend_entries(@graph.stats)}
            type="button"
            data-role="graph-type-toggle"
            data-type={entry.type}
            data-active="true"
            aria-pressed="true"
            class="btn btn-sm btn-soft h-auto gap-2 normal-case px-3 py-2"
          >
            <span
              data-role="graph-type-swatch"
              class="size-3 rounded-full border"
              style={"background-color: #{entry.fill}; border-color: #{entry.border};"}
            />
            <span>{entry.label}</span>
            <span class="rounded-full border border-base-300 px-1.5 py-0.5 text-[11px]">
              {entry.count}
            </span>
          </button>
        </div>

        <p class="mt-2 text-xs text-base-content/60">Filters affect graph visibility only.</p>
      </div>

      <div :if={not Enum.empty?(@graph.expandable_nodes)} class="mt-4">
        <p class="text-xs uppercase tracking-wide text-base-content/70">Expandable</p>
        <div class="mt-2 flex flex-wrap gap-3">
          <button
            :for={node <- @graph.expandable_nodes}
            type="button"
            class="btn btn-sm btn-soft h-auto max-w-full whitespace-normal break-words px-3 py-2 text-left leading-snug"
            phx-click="expand_graph_node"
            phx-value-id={node.id}
          >
            Expand {node.label}
          </button>
        </div>
      </div>
    </section>
    """
  end

  def graph_payload(graph) do
    %{
      mode: graph.mode,
      title: graph.title,
      selection: graph.selection,
      layout_mode: graph.layout_mode,
      type_styles: type_style_map(),
      nodes: Enum.map(graph.nodes, &graph_payload_node/1),
      edges: graph.edges
    }
  end

  defp graph_payload_node(%{type: :cluster} = node) do
    node
    |> Map.put(:display_label, truncate_label(Map.get(node, :graph_label, Map.get(node, :label))))
    |> Map.put(:tooltip_label, Map.get(node, :tooltip_label, Map.get(node, :label)))
  end

  defp graph_payload_node(node) do
    graph_label = Map.get(node, :graph_label, Map.get(node, :label))
    tooltip_label = Map.get(node, :tooltip_label, Map.get(node, :label))

    node
    |> Map.put(:display_label, truncate_label(graph_label))
    |> Map.put(:tooltip_label, tooltip_label)
  end

  defp type_legend_entries(%{type_counts: type_counts}) when is_map(type_counts) do
    type_counts
    |> Enum.sort_by(fn {type, _count} -> to_string(type) end)
    |> Enum.map(fn {type, count} ->
      type_key = to_string(type)
      styles = Map.get(type_style_map(), type_key, default_type_style())

      %{
        type: type_key,
        label: styles.label,
        count: count,
        fill: styles.fill,
        border: styles.border
      }
    end)
  end

  defp type_legend_entries(_stats), do: []

  defp type_style_map do
    %{
      "cluster" => %{label: "cluster", fill: "#e8ecf1", border: "#64748b"},
      "episodic" => %{label: "episodic", fill: "#ffe3ea", border: "#c2416c"},
      "intent" => %{label: "intent", fill: "#e6f7e6", border: "#3a8e44"},
      "procedural" => %{label: "procedural", fill: "#efe9ff", border: "#7059b6"},
      "semantic" => %{label: "semantic", fill: "#daf0ff", border: "#3d83c8"},
      "source" => %{label: "source", fill: "#f2f4f8", border: "#829ab1"},
      "subgoal" => %{label: "subgoal", fill: "#fff1c7", border: "#c18a00"},
      "tag" => %{label: "tag", fill: "#ffe6d3", border: "#ca6a22"}
    }
  end

  defp default_type_style do
    %{label: "other", fill: "#f5f7fa", border: "#51606d"}
  end

  defp truncate_label(nil), do: nil

  defp truncate_label(label) when is_binary(label) do
    if String.length(label) > 18 do
      label
      |> String.slice(0, 15)
      |> Kernel.<>("...")
    else
      label
    end
  end

  defp truncate_label(label), do: label
end
