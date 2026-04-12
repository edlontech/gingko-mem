defmodule GingkoWeb.ProjectLive.MemoriesTabComponent do
  @moduledoc """
  Memories tab for `GingkoWeb.ProjectLive`.

  Presentational LiveComponent rendering recent memories for the active project.
  Receives `memories` and `top_k` from the shell and sends
  `{:recent_memories, :change_top_k, k}` to the parent LiveView when the user
  changes the top_k selector.
  """

  use GingkoWeb, :live_component

  @type_badge_classes %{
    "semantic" => "badge-info",
    "episodic" => "badge-success",
    "procedural" => "badge-warning",
    "intent" => "badge-primary",
    "subgoal" => "badge-secondary"
  }

  @impl true
  def render(assigns) do
    ~H"""
    <details open class="rounded-2xl border border-base-300 bg-base-100 p-4">
      <summary class="flex cursor-pointer items-center justify-between">
        <span class="text-lg font-semibold">Recent Memories</span>
        <form phx-change="change_top_k" phx-target={@myself}>
          <select name="top_k" class="select select-bordered select-xs">
            <option :for={k <- [5, 10, 20]} value={k} selected={k == @top_k}>{k}</option>
          </select>
        </form>
      </summary>

      <div :if={Enum.empty?(@memories)} class="mt-3 text-sm text-base-content/70">
        No recent memories found.
      </div>

      <ul :if={not Enum.empty?(@memories)} class="mt-3 space-y-3">
        <li
          :for={%{node: node, metadata: metadata} <- @memories}
          class="rounded-lg border border-base-300 p-3"
        >
          <div class="flex items-start justify-between gap-2">
            <span class={["badge badge-sm", type_badge_class(node[:type])]}>
              {node[:type]}
            </span>
            <span :if={is_number(metadata[:confidence])} class="text-xs text-base-content/70">
              {Float.round(metadata[:confidence] * 100, 1)}%
            </span>
          </div>
          <p class="mt-2 whitespace-pre-wrap text-sm">{render_content(node)}</p>
          <p :if={metadata[:created_at]} class="mt-1 text-xs text-base-content/50">
            {format_timestamp(metadata[:created_at])}
          </p>
        </li>
      </ul>
    </details>
    """
  end

  @impl true
  def handle_event("change_top_k", %{"top_k" => top_k_str}, socket) do
    top_k = String.to_integer(top_k_str)
    send(self(), {:recent_memories, :change_top_k, top_k})
    {:noreply, socket}
  end

  defp render_content(%{type: "semantic"} = node), do: node[:proposition]

  defp render_content(%{type: "episodic"} = node) do
    parts = []
    parts = if node[:observation], do: ["Observation: #{node[:observation]}" | parts], else: parts
    parts = if node[:action], do: ["Action: #{node[:action]}" | parts], else: parts
    parts = if node[:subgoal], do: ["Subgoal: #{node[:subgoal]}" | parts], else: parts
    Enum.join(Enum.reverse(parts), "\n")
  end

  defp render_content(%{type: "procedural"} = node), do: node[:instruction]
  defp render_content(%{type: "intent"} = node), do: node[:description]
  defp render_content(%{type: "subgoal"} = node), do: node[:description]
  defp render_content(%{type: "tag"} = node), do: node[:label]
  defp render_content(%{type: "source", plain_text: text}) when is_binary(text), do: text
  defp render_content(%{type: "source"} = node), do: "Episode: #{node[:episode_id]}"
  defp render_content(node), do: node[:proposition] || node[:description] || node[:label]

  defp type_badge_class(type), do: Map.get(@type_badge_classes, type, "badge-ghost")

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_timestamp(_), do: ""
end
