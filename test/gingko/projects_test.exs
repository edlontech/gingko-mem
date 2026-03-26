defmodule Gingko.ProjectsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Gingko.Projects
  alias Gingko.Projects.Project
  alias Gingko.Projects.ProjectMemory
  alias Gingko.Projects.Session
  alias Gingko.Repo

  setup do
    Repo.delete_all(Session)
    Repo.delete_all(ProjectMemory)
    Repo.delete_all(Project)
    :ok
  end

  @tag :tmp_dir
  test "register_project/1 creates a project and its root memory", %{tmp_dir: tmp_dir} do
    project_key = "projects-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, project} =
             Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    assert project.project_key == project_key

    root_memory = Projects.get_root_memory!(project.project_key)
    assert root_memory.kind == :root
    assert root_memory.branch_name == nil
    assert String.ends_with?(root_memory.dets_path, "/root.dets")
    assert String.starts_with?(root_memory.dets_path, tmp_dir)
  end

  @tag :tmp_dir
  test "register_project/1 is idempotent for the same project key", %{tmp_dir: tmp_dir} do
    project_key = "projects-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, first} =
             Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    assert {:ok, second} =
             Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    assert first.id == second.id
    assert [stored_project] = Projects.list_projects()
    assert stored_project.project_key == project_key
  end

  @tag :tmp_dir
  test "create_branch_memory/2 persists a named branch memory", %{tmp_dir: tmp_dir} do
    project_key = "projects-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, project} = Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    assert {:ok, branch_memory} =
             Projects.create_branch_memory(project.project_key, "feature/test")

    assert branch_memory.kind == :branch
    assert branch_memory.branch_name == "feature/test"

    fetched = Projects.get_memory!(project.project_key, {:branch, "feature/test"})
    assert fetched.id == branch_memory.id
    assert String.ends_with?(fetched.dets_path, "/branches/feature-test.dets")
  end

  @tag :tmp_dir
  test "create_branch_memory/2 rejects duplicate branch names", %{tmp_dir: tmp_dir} do
    project_key = "projects-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, project} = Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    assert {:ok, _branch_memory} = Projects.create_branch_memory(project.project_key, "feature-a")

    assert {:error, changeset} = Projects.create_branch_memory(project.project_key, "feature-a")
    assert %{branch_name: ["has already been taken"]} = errors_on(changeset)
  end

  describe "sessions" do
    setup %{tmp_dir: tmp_dir} do
      project_key = "projects-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, project} =
        Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      %{project: project, project_key: project_key}
    end

    @tag :tmp_dir
    test "create_session/1 creates an active session", %{project_key: project_key} do
      session_id = "session-#{System.unique_integer([:positive])}"

      assert {:ok, session} =
               Projects.create_session(%{project_key: project_key, session_id: session_id})

      assert session.session_id == session_id
      assert session.status == "active"
      assert session.node_ids == []
      assert session.node_count == 0
      assert session.trajectory_count == 0
      assert session.started_at != nil
      assert session.finished_at == nil
    end

    @tag :tmp_dir
    test "create_session/1 stores the goal when provided", %{project_key: project_key} do
      session_id = "session-#{System.unique_integer([:positive])}"

      assert {:ok, session} =
               Projects.create_session(%{
                 project_key: project_key,
                 session_id: session_id,
                 goal: "implement feature X"
               })

      assert session.goal == "implement feature X"
    end

    @tag :tmp_dir
    test "create_session/1 is idempotent", %{project_key: project_key} do
      session_id = "session-#{System.unique_integer([:positive])}"
      attrs = %{project_key: project_key, session_id: session_id}

      assert {:ok, _first} = Projects.create_session(attrs)
      assert {:ok, _second} = Projects.create_session(attrs)

      sessions = Repo.all(from(s in Session, where: s.session_id == ^session_id))
      assert length(sessions) == 1
    end

    @tag :tmp_dir
    test "create_session/1 returns error for unknown project" do
      assert {:error, :project_not_found} =
               Projects.create_session(%{project_key: "nonexistent", session_id: "s1"})
    end

    @tag :tmp_dir
    test "finish_session/1 marks session as finished with timestamp", %{project_key: project_key} do
      session_id = "session-#{System.unique_integer([:positive])}"
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: session_id})

      assert {:ok, session} = Projects.finish_session(session_id)
      assert session.status == "finished"
      assert session.finished_at != nil
    end

    @tag :tmp_dir
    test "finish_session/1 returns error for unknown session" do
      assert {:error, :session_not_found} = Projects.finish_session("nonexistent")
    end

    @tag :tmp_dir
    test "abandon_active_sessions/0 marks all active sessions as abandoned", %{
      project_key: project_key
    } do
      s1 = "session-#{System.unique_integer([:positive])}"
      s2 = "session-#{System.unique_integer([:positive])}"
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: s1})
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: s2})

      {count, _} = Projects.abandon_active_sessions()
      assert count == 2

      for sid <- [s1, s2] do
        session = Repo.get_by!(Session, session_id: sid)
        assert session.status == "abandoned"
        assert session.finished_at != nil
      end
    end

    @tag :tmp_dir
    test "abandon_active_sessions/0 does not touch finished sessions", %{project_key: project_key} do
      s1 = "session-#{System.unique_integer([:positive])}"
      s2 = "session-#{System.unique_integer([:positive])}"
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: s1})
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: s2})
      {:ok, _} = Projects.finish_session(s1)

      {count, _} = Projects.abandon_active_sessions()
      assert count == 1

      finished = Repo.get_by!(Session, session_id: s1)
      assert finished.status == "finished"

      abandoned = Repo.get_by!(Session, session_id: s2)
      assert abandoned.status == "abandoned"
    end

    @tag :tmp_dir
    test "update_session_trajectory/1 merges node_ids and increments trajectory_count", %{
      project_key: project_key
    } do
      session_id = "session-#{System.unique_integer([:positive])}"
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: session_id})

      {:ok, updated} =
        Projects.update_session_trajectory(%{session_id: session_id, node_ids: ["a", "b"]})

      assert updated.node_ids == ["a", "b"]
      assert updated.node_count == 2
      assert updated.trajectory_count == 1

      {:ok, updated2} =
        Projects.update_session_trajectory(%{session_id: session_id, node_ids: ["b", "c"]})

      assert updated2.node_ids == ["a", "b", "c"]
      assert updated2.node_count == 3
      assert updated2.trajectory_count == 2
    end

    @tag :tmp_dir
    test "update_session_trajectory/1 returns error for unknown session" do
      assert {:error, :session_not_found} =
               Projects.update_session_trajectory(%{session_id: "nonexistent", node_ids: ["a"]})
    end

    @tag :tmp_dir
    test "list_sessions/2 returns sessions ordered by started_at desc", %{
      project_key: project_key
    } do
      s1 = "session-#{System.unique_integer([:positive])}"
      s2 = "session-#{System.unique_integer([:positive])}"
      earlier = ~U[2025-01-01 00:00:00Z]
      later = ~U[2025-06-01 00:00:00Z]

      {:ok, _} =
        Projects.create_session(%{project_key: project_key, session_id: s1, started_at: earlier})

      {:ok, _} =
        Projects.create_session(%{project_key: project_key, session_id: s2, started_at: later})

      sessions = Projects.list_sessions(project_key)
      assert length(sessions) == 2
      assert hd(sessions).session_id == s2
    end

    @tag :tmp_dir
    test "list_sessions/2 filters by status", %{project_key: project_key} do
      s1 = "session-#{System.unique_integer([:positive])}"
      s2 = "session-#{System.unique_integer([:positive])}"
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: s1})
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: s2})
      {:ok, _} = Projects.finish_session(s1)

      active = Projects.list_sessions(project_key, status: "active")
      assert length(active) == 1
      assert hd(active).session_id == s2

      finished = Projects.list_sessions(project_key, status: "finished")
      assert length(finished) == 1
      assert hd(finished).session_id == s1
    end

    @tag :tmp_dir
    test "get_session_node_ids/1 returns node_ids for existing session", %{
      project_key: project_key
    } do
      session_id = "session-#{System.unique_integer([:positive])}"
      {:ok, _} = Projects.create_session(%{project_key: project_key, session_id: session_id})

      {:ok, _} =
        Projects.update_session_trajectory(%{session_id: session_id, node_ids: ["x", "y"]})

      assert Projects.get_session_node_ids(session_id) == ["x", "y"]
    end

    @tag :tmp_dir
    test "get_session_node_ids/1 returns empty list for unknown session" do
      assert Projects.get_session_node_ids("nonexistent") == []
    end
  end

  describe "extraction overlays" do
    setup %{tmp_dir: tmp_dir} do
      project_key = "projects-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, _project} =
        Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      %{project_key: project_key}
    end

    @tag :tmp_dir
    test "get_extraction_overlay/1 returns defaults for a fresh project", %{
      project_key: project_key
    } do
      overlay = Projects.get_extraction_overlay(project_key)
      assert overlay.base == "inherit_global"
      assert overlay.steps == %{}
      assert Gingko.Projects.ExtractionOverlay.empty?(overlay)
    end

    @tag :tmp_dir
    test "update_extraction_overlay/2 persists base, context, and steps", %{
      project_key: project_key
    } do
      attrs = %{
        "base" => "coding",
        "domain_context" => "GenServer-heavy codebase",
        "steps" => %{"get_semantic" => "Focus on OTP patterns."}
      }

      assert {:ok, project} = Projects.update_extraction_overlay(project_key, attrs)
      assert project.overlay_base == "coding"
      assert project.overlay_updated_at != nil

      overlay = Projects.get_extraction_overlay(project_key)
      assert overlay.base == "coding"
      assert overlay.domain_context == "GenServer-heavy codebase"
      assert overlay.steps == %{get_semantic: "Focus on OTP patterns."}
    end

    @tag :tmp_dir
    test "update_extraction_overlay/2 broadcasts on the overlays topic", %{
      project_key: project_key
    } do
      :ok = Projects.subscribe_overlays()

      assert {:ok, _} =
               Projects.update_extraction_overlay(project_key, %{
                 "base" => "none",
                 "steps" => %{"get_plan" => "plan"}
               })

      assert_receive {:overlay_updated, ^project_key}, 500
    end

    @tag :tmp_dir
    test "reset_extraction_overlay/1 clears back to defaults", %{project_key: project_key} do
      {:ok, _} =
        Projects.update_extraction_overlay(project_key, %{
          "base" => "coding",
          "steps" => %{"get_semantic" => "x"}
        })

      assert {:ok, _} = Projects.reset_extraction_overlay(project_key)
      overlay = Projects.get_extraction_overlay(project_key)
      assert overlay.base == "inherit_global"
      assert overlay.steps == %{}
    end

    @tag :tmp_dir
    test "custom_overlays?/1 detects any override", %{project_key: project_key} do
      project = Projects.get_project_by_key!(project_key)
      refute Projects.custom_overlays?(project)

      {:ok, project} =
        Projects.update_extraction_overlay(project_key, %{"base" => "coding"})

      assert Projects.custom_overlays?(project)
    end

    @tag :tmp_dir
    test "update_extraction_overlay/2 surfaces validation errors", %{project_key: project_key} do
      assert {:error, %Ecto.Changeset{}} =
               Projects.update_extraction_overlay(project_key, %{"base" => "unknown"})
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
