defmodule GingkoWeb.ProjectLive.HealthTabComponent do
  @moduledoc """
  Health tab for `GingkoWeb.ProjectLive`.

  Displays quality metrics, orphan nodes and low-confidence nodes for the
  current project. Row clicks patch to the graph tab focused on the node.
  Receives `quality`, `node_map` and `project_id` from the shell; owns only
  its local confidence-threshold filter state.
  """

  use GingkoWeb, :live_component

  alias Mnemosyne.Graph.Node.Semantic

  @default_threshold 0.5

  @impl true
  def update(assigns, socket) do
    threshold = socket.assigns[:threshold] || @default_threshold
    orphans = compute_orphans(assigns.node_map)
    low_conf_nodes = filter_low_confidence(assigns.node_map, threshold)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:threshold, threshold)
     |> assign(:orphans, orphans)
     |> assign(:low_conf_nodes, low_conf_nodes)}
  end

  @impl true
  def handle_event("set_threshold", %{"value" => value}, socket) do
    case Float.parse(value) do
      {threshold, _} ->
        nodes = filter_low_confidence(socket.assigns.node_map, threshold)

        {:noreply,
         socket
         |> assign(:threshold, threshold)
         |> assign(:low_conf_nodes, nodes)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="grid grid-cols-2 gap-3 md:grid-cols-4 lg:grid-cols-7">
        <.quality_card label="Total Nodes" value={@quality.total_nodes} />
        <.quality_card label="Total Edges" value={@quality.total_edges} />
        <.quality_card label="Orphans" value={@quality.orphan_count} />
        <.quality_card label="Avg Confidence" value={format_confidence(@quality.avg_confidence)} />
        <.quality_card label="Last Decay" value={format_timestamp(@quality.last_decay_at)} />
        <.quality_card
          label="Last Consolidation"
          value={format_timestamp(@quality.last_consolidation_at)}
        />
        <.quality_card
          label="Last Validation"
          value={format_timestamp(@quality.last_validation_at)}
        />
      </div>

      <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <section class="rounded-2xl border border-base-300 bg-base-100 p-4">
          <h3 class="text-lg font-semibold">Orphans</h3>
          <p class="text-xs text-base-content/60 mt-1 mb-3">{length(@orphans)} orphaned nodes</p>

          <div :if={Enum.empty?(@orphans)} class="text-sm text-base-content/60">
            No orphaned nodes in this graph.
          </div>

          <table :if={not Enum.empty?(@orphans)} class="w-full text-sm">
            <thead>
              <tr class="border-b border-base-300 text-left text-xs uppercase tracking-wide text-base-content/50">
                <th class="pb-2 pr-4">Type</th>
                <th class="pb-2 pr-4">Label</th>
                <th class="pb-2">ID</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-200">
              <tr :for={node <- @orphans} class="hover:bg-base-200">
                <td class="py-2 pr-4 font-mono text-xs">{node_type(node)}</td>
                <td class="py-2 pr-4 max-w-xs truncate">
                  <.link
                    patch={~p"/projects/#{@project_id}/graph?node=#{node.id}"}
                    class="hover:underline"
                  >
                    {node_label(node)}
                  </.link>
                </td>
                <td class="py-2 font-mono text-xs text-base-content/50">{node.id}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section class="rounded-2xl border border-base-300 bg-base-100 p-4">
          <h3 class="text-lg font-semibold">Low Confidence</h3>

          <form phx-change="set_threshold" phx-target={@myself} class="mt-2 flex items-center gap-3">
            <label class="text-sm" for={"#{@id}-threshold"}>Confidence threshold</label>
            <input
              id={"#{@id}-threshold"}
              type="range"
              name="value"
              min="0"
              max="1"
              step="0.05"
              value={@threshold}
              class="range range-xs w-48"
            />
            <span class="font-mono text-sm">
              {:erlang.float_to_binary(@threshold * 1.0, decimals: 2)}
            </span>
          </form>

          <p class="text-xs text-base-content/60 mt-2 mb-3">
            {length(@low_conf_nodes)} nodes below threshold
          </p>

          <div :if={Enum.empty?(@low_conf_nodes)} class="text-sm text-base-content/60">
            No semantic nodes below this threshold.
          </div>

          <ul class="space-y-2">
            <li
              :for={{node, conf} <- @low_conf_nodes}
              class="rounded-lg border border-base-300 bg-base-100 px-4 py-3"
            >
              <.link
                patch={~p"/projects/#{@project_id}/graph?node=#{node.id}"}
                class="block hover:underline"
              >
                <div class="flex items-start justify-between gap-4">
                  <p class="text-sm">{node.proposition}</p>
                  <span class="shrink-0 font-mono text-xs text-warning">
                    {:erlang.float_to_binary(conf * 1.0, decimals: 2)}
                  </span>
                </div>
                <p class="mt-1 font-mono text-xs text-base-content/40">{node.id}</p>
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp quality_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-3">
      <div class="text-xs uppercase tracking-wide text-base-content/60">{@label}</div>
      <div class="mt-1 font-mono text-lg">{@value}</div>
    </div>
    """
  end

  defp compute_orphans(node_map) when is_map(node_map) do
    node_map
    |> Map.values()
    |> Enum.filter(&orphan?/1)
    |> Enum.sort_by(&{node_type(&1), node_label(&1)})
  end

  defp compute_orphans(_), do: []

  defp filter_low_confidence(node_map, threshold) when is_map(node_map) do
    node_map
    |> Map.values()
    |> Enum.filter(&is_struct(&1, Semantic))
    |> Enum.flat_map(fn node ->
      case node.confidence do
        c when is_number(c) and c < threshold -> [{node, c}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_n, c} -> c end)
  end

  defp filter_low_confidence(_, _), do: []

  defp orphan?(%{links: links}) when is_map(links) do
    Enum.all?(links, fn {_type, ids} -> MapSet.size(ids) == 0 end)
  end

  defp orphan?(%{links: nil}), do: true
  defp orphan?(_), do: false

  defp node_type(%module{}), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp node_label(%{label: l}) when is_binary(l), do: l
  defp node_label(%{proposition: p}) when is_binary(p), do: p
  defp node_label(%{description: d}) when is_binary(d), do: d
  defp node_label(%{observation: o}) when is_binary(o), do: o
  defp node_label(%{id: id}), do: id

  defp format_confidence(nil), do: "n/a"
  defp format_confidence(conf) when is_number(conf), do: "#{Float.round(conf * 100, 1)}%"

  defp format_timestamp(nil), do: "n/a"
  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
