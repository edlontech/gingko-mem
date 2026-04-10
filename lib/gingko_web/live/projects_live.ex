defmodule GingkoWeb.ProjectsLive do
  @moduledoc """
  Card-based landing page for registered projects.

  Subscribes to project registration changes and debounced per-project stats
  broadcasts; re-queries `Gingko.Memory.list_projects_with_stats/0` on each
  relevant message.
  """

  use GingkoWeb, :live_view

  alias Gingko.Memory
  alias Gingko.Projects

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Projects.subscribe_projects()
      Memory.subscribe_projects_stats()
    end

    {:ok, assign_projects(socket)}
  end

  @impl true
  def handle_info({:project_stats_changed, _project_id}, socket) do
    {:noreply, assign_projects(socket)}
  end

  def handle_info(:projects_changed, socket) do
    {:noreply, assign_projects(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={assigns[:page_title]}>
      <section class="mx-auto w-full max-w-[112rem] px-4 py-6 sm:px-6 lg:px-8">
        <.header>
          Projects
          <:subtitle>{length(@projects)} registered</:subtitle>
        </.header>

        <div
          :if={Enum.empty?(@projects)}
          class="mt-6 rounded-2xl border border-dashed border-base-300 bg-base-100 p-6 text-sm text-base-content/70"
        >
          No projects registered. Open one via MCP to get started.
        </div>

        <div
          :if={not Enum.empty?(@projects)}
          class="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
        >
          <.link
            :for={project <- @projects}
            navigate={~p"/projects/#{project.project_id}/memories"}
            class="rounded-2xl border border-base-300 bg-base-100 p-4 transition hover:border-primary hover:bg-base-200"
          >
            <p class="text-lg font-semibold">{project.display_name}</p>
            <p class="font-mono text-xs text-base-content/60">{project.project_id}</p>

            <div class="mt-3 border-t border-base-200 pt-3 text-xs text-base-content/80">
              <p>{project.total_nodes} nodes · {project.total_edges} edges</p>
              <p class="mt-1 flex flex-wrap items-center gap-2">
                <span class={[
                  "inline-flex items-center gap-1",
                  active_class(project.active_sessions)
                ]}>
                  ● {project.active_sessions} active
                </span>
                <span :if={project.orphan_count > 0} class="badge badge-warning badge-sm">
                  ⚠ {project.orphan_count} orphans
                </span>
                <span :if={project.avg_confidence}>
                  {Float.round(project.avg_confidence * 100, 1)}% conf
                </span>
              </p>
              <p :if={project.last_activity_at} class="mt-1 text-base-content/50">
                last activity ·
                <span
                  phx-hook="RelativeTime"
                  id={"last-activity-#{project.project_id}"}
                  data-timestamp={DateTime.to_iso8601(project.last_activity_at)}
                >
                  {Calendar.strftime(project.last_activity_at, "%Y-%m-%d %H:%M")}
                </span>
              </p>
            </div>
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp assign_projects(socket) do
    %{projects: projects} = Memory.list_projects_with_stats()
    assign(socket, :projects, sort(projects))
  end

  defp sort(projects) do
    Enum.sort_by(projects, fn p ->
      {-unix_micros(p.last_activity_at), p.display_name}
    end)
  end

  defp unix_micros(nil), do: 0
  defp unix_micros(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp active_class(n) when n > 0, do: "text-success"
  defp active_class(_), do: "text-base-content/40"
end
