defmodule GingkoWeb.ProjectsLiveTest do
  use GingkoWeb.ConnCase, async: false
  use Mimic

  alias Gingko.Memory

  setup :set_mimic_global

  setup do
    Mimic.copy(Gingko.Memory)
    :ok
  end

  test "renders empty state when there are no projects", %{conn: conn} do
    stub(Memory, :list_projects_with_stats, fn -> %{projects: []} end)

    {:ok, _view, html} = live conn, ~p"/projects"

    assert html =~ "Projects"
    assert html =~ "0 registered"
    assert html =~ "No projects registered"
  end

  test "renders two project cards in sort order by last_activity_at desc", %{conn: conn} do
    older = DateTime.add(DateTime.utc_now(), -3600, :second)
    newer = DateTime.add(DateTime.utc_now(), -60, :second)

    stub(Memory, :list_projects_with_stats, fn ->
      %{
        projects: [
          project_entry("alpha", "Alpha Project", older, 12, 24, 0, 0, 0.9),
          project_entry("beta", "Beta Project", newer, 5, 10, 2, 1, 0.42)
        ]
      }
    end)

    {:ok, _view, html} = live conn, ~p"/projects"

    assert html =~ "2 registered"

    assert html =~ "Alpha Project"
    assert html =~ "alpha"
    assert html =~ "Beta Project"
    assert html =~ "beta"

    beta_idx = :binary.match(html, "Beta Project") |> elem(0)
    alpha_idx = :binary.match(html, "Alpha Project") |> elem(0)
    assert beta_idx < alpha_idx
  end

  test "ties on last_activity_at break by display_name asc", %{conn: conn} do
    same = DateTime.utc_now()

    stub(Memory, :list_projects_with_stats, fn ->
      %{
        projects: [
          project_entry("z-id", "Zeta", same, 1, 2, 0, 0, nil),
          project_entry("a-id", "Alpha", same, 1, 2, 0, 0, nil)
        ]
      }
    end)

    {:ok, _view, html} = live conn, ~p"/projects"

    alpha_idx = :binary.match(html, "Alpha") |> elem(0)
    zeta_idx = :binary.match(html, "Zeta") |> elem(0)
    assert alpha_idx < zeta_idx
  end

  test "card markup includes all required fields", %{conn: conn} do
    last = DateTime.utc_now()

    stub(Memory, :list_projects_with_stats, fn ->
      %{
        projects: [
          project_entry("proj-x", "Project X", last, 1247, 3108, 3, 2, 0.913)
        ]
      }
    end)

    {:ok, _view, html} = live conn, ~p"/projects"

    assert html =~ "Project X"
    assert html =~ "proj-x"
    assert html =~ "1247 nodes"
    assert html =~ "3108 edges"
    assert html =~ "2 active"
    assert html =~ "3 orphans"
    assert html =~ "91.3% conf"
    assert html =~ ~s|phx-hook="RelativeTime"|
    assert html =~ ~s|id="last-activity-proj-x"|
    assert html =~ DateTime.to_iso8601(last)
    assert html =~ "/projects/proj-x/memories"
  end

  test "orphans badge is hidden when orphan_count is 0", %{conn: conn} do
    stub(Memory, :list_projects_with_stats, fn ->
      %{
        projects: [
          project_entry("clean", "Clean", DateTime.utc_now(), 10, 5, 0, 0, nil)
        ]
      }
    end)

    {:ok, _view, html} = live conn, ~p"/projects"

    refute html =~ "orphans"
  end

  test "clicking a card navigates to /projects/:project_id/memories", %{conn: conn} do
    stub(Memory, :list_projects_with_stats, fn ->
      %{
        projects: [
          project_entry("go-there", "Go There", DateTime.utc_now(), 1, 1, 0, 0, nil)
        ]
      }
    end)

    {:ok, view, _html} = live conn, ~p"/projects"

    assert view
           |> element(~s|a[href="/projects/go-there/memories"]|)
           |> has_element?()
  end

  test "{:project_stats_changed, project_id} triggers re-render with fresh numbers", %{conn: conn} do
    {:ok, agent} = Agent.start_link(fn -> 5 end)

    stub(Memory, :list_projects_with_stats, fn ->
      nodes = Agent.get(agent, & &1)

      %{
        projects: [
          project_entry(
            "live",
            "Live",
            DateTime.utc_now(),
            nodes,
            nodes * 2,
            0,
            0,
            nil
          )
        ]
      }
    end)

    {:ok, view, html} = live conn, ~p"/projects"
    assert html =~ "5 nodes"

    Agent.update(agent, fn _ -> 42 end)

    send(view.pid, {:project_stats_changed, "live"})

    rendered = render(view)
    assert rendered =~ "42 nodes"
    refute rendered =~ "5 nodes"
  end

  test ":projects_changed triggers re-render with new project appended", %{conn: conn} do
    {:ok, agent} =
      Agent.start_link(fn ->
        [project_entry("first", "First", DateTime.utc_now(), 1, 1, 0, 0, nil)]
      end)

    stub(Memory, :list_projects_with_stats, fn ->
      %{projects: Agent.get(agent, & &1)}
    end)

    {:ok, view, html} = live conn, ~p"/projects"
    assert html =~ "First"
    assert html =~ "1 registered"
    refute html =~ "Second"

    Agent.update(agent, fn current ->
      [project_entry("second", "Second", DateTime.utc_now(), 2, 2, 0, 0, nil) | current]
    end)

    send(view.pid, :projects_changed)

    rendered = render(view)
    assert rendered =~ "Second"
    assert rendered =~ "2 registered"
  end

  defp project_entry(
         project_id,
         display_name,
         last_activity_at,
         nodes,
         edges,
         orphans,
         active,
         avg_conf
       ) do
    %{
      project_id: project_id,
      display_name: display_name,
      total_nodes: nodes,
      total_edges: edges,
      orphan_count: orphans,
      avg_confidence: avg_conf,
      active_sessions: active,
      last_activity_at: last_activity_at
    }
  end
end
