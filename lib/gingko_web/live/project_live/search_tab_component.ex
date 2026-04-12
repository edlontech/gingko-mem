defmodule GingkoWeb.ProjectLive.SearchTabComponent do
  @moduledoc """
  Search tab for `GingkoWeb.ProjectLive`.

  Presentational LiveComponent rendering a search form over the project's
  memory graph. Receives `query_text`, `query_status`, `query_result` and
  `project_id` from the shell; dispatches `{:search, :submit, query}` to the
  parent LiveView on submit. The shell owns the async Task lifecycle and the
  result/error state; the component simply re-renders from the props it
  receives.
  """

  use GingkoWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <form phx-submit="submit_search" phx-target={@myself} class="flex flex-col gap-2">
        <textarea
          name="query"
          rows="3"
          class="textarea textarea-bordered w-full"
          placeholder="Search memories with a natural language query..."
        >{@query_text}</textarea>
        <div class="flex justify-end">
          <button
            type="submit"
            class="btn btn-primary"
            disabled={@query_status == :searching}
          >
            <span
              :if={@query_status == :searching}
              class="loading loading-spinner loading-sm"
            /> Search
          </button>
        </div>
      </form>

      <div
        :if={@query_status == :idle}
        class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
      >
        Enter a natural language query to search the memory graph.
      </div>

      <div
        :if={@query_status == :searching}
        class="flex items-center justify-center gap-3 rounded-2xl border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
      >
        <span class="loading loading-spinner loading-sm"></span> Recalling memories...
      </div>

      <div
        :if={@query_status == :error}
        class="rounded-2xl border border-error/40 bg-error/10 p-4 text-sm text-error"
      >
        Search failed. Try a different query or refresh the page.
      </div>

      <div :if={@query_status == :completed} class="space-y-4">
        <.memory_section
          :if={has_content?(memory_field(@query_result, :semantic))}
          type="Semantic"
          badge_class="badge-info"
          content={memory_field(@query_result, :semantic)}
        />
        <.memory_section
          :if={has_content?(memory_field(@query_result, :episodic))}
          type="Episodic"
          badge_class="badge-success"
          content={memory_field(@query_result, :episodic)}
        />
        <.memory_section
          :if={has_content?(memory_field(@query_result, :procedural))}
          type="Procedural"
          badge_class="badge-warning"
          content={memory_field(@query_result, :procedural)}
        />

        <div class="rounded-2xl border border-base-300 bg-base-100 p-4">
          <h3 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            Matched nodes
          </h3>

          <div
            :if={Enum.empty?(touched_nodes(@query_result))}
            class="mt-3 text-sm text-base-content/60"
          >
            No matches found.
          </div>

          <ul :if={not Enum.empty?(touched_nodes(@query_result))} class="mt-3 space-y-2">
            <li :for={node_id <- touched_nodes(@query_result)}>
              <.link
                patch={~p"/projects/#{@project_id}/graph?node=#{node_id}"}
                class="block rounded-lg border border-base-300 px-3 py-2 font-mono text-xs hover:border-primary hover:bg-base-200"
              >
                {node_id}
              </.link>
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("submit_search", %{"query" => query}, socket) do
    case String.trim(query) do
      "" ->
        {:noreply, socket}

      trimmed ->
        send(self(), {:search, :submit, trimmed})
        {:noreply, socket}
    end
  end

  defp memory_section(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-4">
      <span class={["badge badge-sm", @badge_class]}>{@type}</span>
      <p class="mt-2 whitespace-pre-wrap text-sm">{@content}</p>
    </div>
    """
  end

  defp memory_field(nil, _key), do: nil
  defp memory_field(%{memory: memory}, key) when is_map(memory), do: Map.get(memory, key)
  defp memory_field(%{} = result, key), do: Map.get(result, key)

  defp touched_nodes(nil), do: []
  defp touched_nodes(%{touched_node_ids: ids}) when is_list(ids), do: ids
  defp touched_nodes(_), do: []

  defp has_content?(nil), do: false
  defp has_content?(""), do: false
  defp has_content?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_content?(_), do: true
end
