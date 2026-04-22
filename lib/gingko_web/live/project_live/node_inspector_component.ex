defmodule GingkoWeb.ProjectLive.NodeInspectorComponent do
  @moduledoc false

  use GingkoWeb, :live_component

  @impl true
  def render(assigns) do
    selected_node =
      Enum.find(assigns.graph.nodes, fn node ->
        node.id == Map.get(assigns.graph.selection, :node_id)
      end)

    neighbors =
      selected_node
      |> neighbor_ids(assigns.graph.edges)
      |> Enum.map(fn node_id -> Enum.find(assigns.graph.nodes, &(&1.id == node_id)) end)
      |> Enum.reject(&is_nil/1)

    assigns = assign(assigns, selected_node: selected_node, neighbors: neighbors)

    ~H"""
    <section class="rounded-2xl border border-base-300 bg-base-100 p-4">
      <.header>Node Inspector</.header>
      <div :if={is_nil(@selected_node)} class="mt-3 text-sm text-base-content/70">
        Select a graph node to inspect its relationships.
      </div>
      <div :if={@selected_node} class="mt-3 space-y-3">
        <div class="rounded-xl border border-base-300 bg-base-100 p-4">
          <div class="flex items-start justify-between gap-3">
            <p class="font-mono text-xs">{@selected_node.id}</p>
            <span
              :if={selected_in_graph?(@selected_node)}
              class="rounded-full border border-primary/40 bg-primary/10 px-2 py-0.5 text-[11px] font-medium text-primary"
            >
              Selected in graph
            </span>
          </div>
          <p class="mt-1 text-lg font-semibold leading-6 whitespace-normal break-words">
            {@selected_node.label}
          </p>
          <p class="text-sm text-base-content/70">Type: {@selected_node.type}</p>
          <p class="text-sm text-base-content/70">Degree: {Map.get(@selected_node, :degree, 0)}</p>
        </div>

        <div :if={not Enum.empty?(Map.get(@selected_node, :details, []))}>
          <p class="text-xs uppercase tracking-wide text-base-content/70">Details</p>
          <dl class="mt-2 space-y-2">
            <div :for={field <- @selected_node.details} class="rounded-lg bg-base-200 px-3 py-2">
              <dt class="text-[11px] font-medium uppercase tracking-wide text-base-content/60">
                {field.label}
              </dt>
              <dd class="mt-0.5 whitespace-pre-wrap break-words text-sm">{field.value}</dd>
            </div>
          </dl>
        </div>

        <div>
          <p class="text-xs uppercase tracking-wide text-base-content/70">Neighbors</p>
          <div :if={Enum.empty?(@neighbors)} class="mt-2 text-sm text-base-content/70">
            No visible neighbors in this slice.
          </div>
          <ul :if={not Enum.empty?(@neighbors)} class="mt-2 space-y-2">
            <li :for={node <- @neighbors}>
              <button
                type="button"
                class="btn btn-block h-auto min-h-0 justify-start btn-soft px-3 py-3 normal-case"
                phx-click="select_graph_node"
                phx-value-id={node.id}
              >
                <span class="flex min-w-0 flex-col items-start gap-1 text-left">
                  <span class="font-mono text-xs">{node.id}</span>
                  <span
                    data-role="neighbor-label"
                    class="max-w-full whitespace-normal break-words text-sm leading-5"
                  >
                    {node.label}
                  </span>
                </span>
              </button>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  defp neighbor_ids(nil, _edges), do: []

  defp neighbor_ids(selected_node, edges) do
    selected_id = selected_node.id

    Enum.flat_map(edges, fn
      %{source: ^selected_id, target: target} -> [target]
      %{source: source, target: ^selected_id} -> [source]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp selected_in_graph?(%{classes: classes}) when is_list(classes), do: "is-selected" in classes
  defp selected_in_graph?(_node), do: false
end
