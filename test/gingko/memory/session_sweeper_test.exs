defmodule Gingko.Memory.SessionSweeperTest do
  use ExUnit.Case, async: false

  alias Gingko.Memory.SessionSweeper
  alias Gingko.Projects
  alias Gingko.Projects.Project
  alias Gingko.Projects.ProjectMemory
  alias Gingko.Projects.Session
  alias Gingko.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Repo.delete_all(Session)
    Repo.delete_all(ProjectMemory)
    Repo.delete_all(Project)

    project_key = "sweeper-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _project} =
      Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    %{project_key: project_key}
  end

  test "sweeps sessions that exceed the stale threshold", %{project_key: project_key} do
    session_id = "stale-session-#{System.unique_integer([:positive])}"
    stale_time = DateTime.add(DateTime.utc_now(), -3600, :second)

    {:ok, _} =
      Projects.create_session(%{
        project_key: project_key,
        session_id: session_id,
        started_at: stale_time
      })

    import Ecto.Query
    Repo.update_all(where(Session, session_id: ^session_id), set: [updated_at: stale_time])

    active = Projects.list_sessions(project_key, status: "active")
    assert length(active) == 1

    send(SessionSweeper, :sweep)
    Process.sleep(100)

    active_after = Projects.list_sessions(project_key, status: "active")
    assert active_after == []
  end

  test "keeps sessions that are still within the threshold", %{project_key: project_key} do
    session_id = "fresh-session-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Projects.create_session(%{
        project_key: project_key,
        session_id: session_id
      })

    send(SessionSweeper, :sweep)
    Process.sleep(100)

    active = Projects.list_sessions(project_key, status: "active")
    assert length(active) == 1
  end
end
