defmodule GingkoWeb.ProjectLive.SummariesTabComponent do
  @moduledoc """
  Summaries tab for `GingkoWeb.ProjectLive`.

  Two panels:

    * Charter — editable user-authored project intent (unless the row is
      locked); saving dispatches `Gingko.Summaries.set_charter/2`.
    * Summary — read-only preview of the LLM-generated project summary plus
      a "Regenerate" button that enqueues `ProjectSummaryWorker`.
  """

  use GingkoWeb, :live_component

  require Logger

  alias Gingko.Summaries
  alias Gingko.Summaries.PrincipalMemorySection
  alias Gingko.Summaries.ProjectSummaryWorker

  @impl true
  def update(assigns, socket) do
    %{project_id: project_id} = assigns

    charter = Summaries.get_section(project_id, "charter")
    summary = Summaries.get_section(project_id, "summary")

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:charter, charter)
     |> assign(:summary, summary)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <.panel title="Charter">
        <div :if={charter_locked?(@charter)} class="mb-2 text-xs text-warning">
          Charter is locked — saving is disabled.
        </div>
        <form
          id="summaries-charter-form"
          phx-submit="save_charter"
          phx-target={@myself}
          class="space-y-2"
        >
          <textarea
            name="content"
            rows="8"
            class="textarea textarea-bordered w-full font-mono text-sm"
            placeholder="No charter set yet. Describe the project's goals, boundaries, and non-goals."
            disabled={charter_locked?(@charter)}
          >{section_content(@charter)}</textarea>
          <div class="flex justify-end">
            <button
              type="submit"
              class="btn btn-primary"
              disabled={charter_locked?(@charter)}
            >
              Save charter
            </button>
          </div>
        </form>
      </.panel>

      <.panel title="Summary">
        <div class="flex justify-end">
          <button
            type="button"
            phx-click="refresh_summary"
            phx-target={@myself}
            class="btn btn-sm"
          >
            Regenerate
          </button>
        </div>
        <.markdown_preview content={section_content(@summary)} placeholder="No summary yet." />
      </.panel>
    </section>
    """
  end

  @impl true
  def handle_event("save_charter", %{"content" => content}, socket) do
    project_id = socket.assigns.project_id

    case Summaries.set_charter(project_id, content) do
      {:ok, section} ->
        forward_flash(:info, "Charter saved.")
        {:noreply, assign(socket, :charter, section)}

      {:error, %{code: :charter_locked, message: message}} ->
        forward_flash(:error, message)
        {:noreply, socket}

      {:error, %{code: :invalid_params, message: message}} ->
        forward_flash(:error, message)
        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("set_charter changeset errors: #{inspect(changeset.errors)}")
        forward_flash(:error, "Could not save charter: please check the content and try again.")
        {:noreply, socket}
    end
  end

  def handle_event("refresh_summary", _params, socket) do
    project_id = socket.assigns.project_id

    case %{project_key: project_id}
         |> ProjectSummaryWorker.new(unique: false)
         |> Oban.insert() do
      {:ok, _job} ->
        forward_flash(:info, "Summary regeneration enqueued.")
        {:noreply, socket}

      {:error, reason} ->
        forward_flash(:error, "Could not enqueue regeneration: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  defp forward_flash(kind, message) do
    send(self(), {:put_flash, kind, message})
  end

  defp panel(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-4">
      <div class="mb-3 flex items-center justify-between">
        <h2 class="text-lg font-semibold">{@title}</h2>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp markdown_preview(assigns) do
    ~H"""
    <div
      :if={is_binary(@content) and @content != ""}
      class="prose prose-sm max-w-none whitespace-pre-wrap rounded-lg border border-base-300 bg-base-200 p-3 font-mono text-sm"
    >
      {@content}
    </div>
    <div
      :if={@content in [nil, ""]}
      class="text-sm text-base-content/70"
    >
      {@placeholder}
    </div>
    """
  end

  defp section_content(nil), do: nil
  defp section_content(%PrincipalMemorySection{content: content}), do: content

  defp charter_locked?(%PrincipalMemorySection{locked: true}), do: true
  defp charter_locked?(_), do: false
end
