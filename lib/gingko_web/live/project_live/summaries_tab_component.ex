defmodule GingkoWeb.ProjectLive.SummariesTabComponent do
  @moduledoc """
  Summaries tab for `GingkoWeb.ProjectLive`.

  Four panels over the derived-memory artifacts maintained by `Gingko.Summaries`:

    * Playbook — read-only preview of the static recall playbook.
    * Charter — editable prose (unless the row is locked); saving dispatches
      `Gingko.Summaries.set_charter/2`.
    * State — read-only preview of the latest tier-0 state section plus a
      "Regenerate" button that delegates to `Gingko.Summaries.Refresh.run/3`.
    * Clusters — table of tier-1 cluster summaries with per-row regenerate
      buttons, also going through `Gingko.Summaries.Refresh.run/3`.

  The component owns its own summary/cluster state locally (loaded in
  `update/2`) to keep the shell LiveView focused on project-wide assigns.
  """

  use GingkoWeb, :live_component

  require Logger

  alias Gingko.Summaries
  alias Gingko.Summaries.PrincipalMemorySection
  alias Gingko.Summaries.Refresh

  @impl true
  def update(assigns, socket) do
    %{project_id: project_id} = assigns

    playbook = Summaries.get_section(project_id, "playbook")
    charter = Summaries.get_section(project_id, "charter")
    state = Summaries.get_section(project_id, "state")
    clusters = Summaries.list_clusters(project_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:playbook, playbook)
     |> assign(:charter, charter)
     |> assign(:state, state)
     |> assign(:clusters, clusters)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <.panel title="Playbook">
        <.markdown_preview content={section_content(@playbook)} placeholder="No playbook seeded yet." />
      </.panel>

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

      <.panel title="State">
        <div class="flex justify-end">
          <button
            type="button"
            phx-click="refresh_principal_memory"
            phx-value-scope="state"
            phx-target={@myself}
            class="btn btn-sm"
          >
            Regenerate
          </button>
        </div>
        <.markdown_preview content={section_content(@state)} placeholder="No state summary yet." />
      </.panel>

      <.panel title="Clusters">
        <div
          :if={Enum.empty?(@clusters)}
          class="text-sm text-base-content/70"
        >
          No cluster summaries yet.
        </div>

        <div :if={not Enum.empty?(@clusters)} class="overflow-x-auto">
          <table class="table table-zebra table-sm">
            <thead>
              <tr>
                <th>Slug</th>
                <th>Headline</th>
                <th class="text-right">Memories</th>
                <th>Last generated</th>
                <th>Status</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={cluster <- @clusters}>
                <td class="font-mono text-xs">{cluster.slug}</td>
                <td>{cluster.headline || "—"}</td>
                <td class="text-right tabular-nums">{cluster.memory_count}</td>
                <td class="text-xs text-base-content/70">
                  {format_relative(cluster.last_generated_at)}
                </td>
                <td>
                  <span :if={cluster.dirty} class="badge badge-warning badge-sm">dirty</span>
                  <span :if={not cluster.dirty} class="badge badge-ghost badge-sm">clean</span>
                </td>
                <td class="text-right">
                  <button
                    type="button"
                    phx-click="refresh_principal_memory"
                    phx-value-scope="cluster"
                    phx-value-slug={cluster.slug}
                    phx-target={@myself}
                    class="btn btn-ghost btn-xs"
                  >
                    Regenerate
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
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

  def handle_event("refresh_principal_memory", %{"scope" => "state"}, socket) do
    project_id = socket.assigns.project_id

    case Refresh.run(project_id, "state") do
      {:ok, _} ->
        forward_flash(:info, "Principal state regeneration enqueued.")
        {:noreply, socket}

      {:error, %{message: message}} ->
        forward_flash(:error, "Could not enqueue regeneration: #{message}")
        {:noreply, socket}
    end
  end

  def handle_event("refresh_principal_memory", %{"scope" => "cluster", "slug" => slug}, socket) do
    project_id = socket.assigns.project_id

    case Refresh.run(project_id, "cluster", slug) do
      {:ok, _} ->
        forward_flash(:info, "Cluster regeneration enqueued for #{slug}.")
        {:noreply, socket}

      {:error, %{message: message}} ->
        forward_flash(:error, "Could not enqueue regeneration: #{message}")
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

  defp format_relative(nil), do: "never"

  defp format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
