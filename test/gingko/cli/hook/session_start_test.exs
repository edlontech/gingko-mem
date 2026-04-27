defmodule Gingko.CLI.Hook.SessionStartTest do
  use ExUnit.Case, async: true
  use Mimic

  import ExUnit.CaptureIO

  alias Gingko.CLI.Hook.SessionStart
  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  setup do
    Mimic.copy(MemoryClient)
    Mimic.copy(ProjectId)

    project_id = "ssstart-#{System.unique_integer([:positive])}"
    stub(ProjectId, :detect, fn -> project_id end)

    on_exit(fn -> SessionFile.clear(project_id) end)
    {:ok, project_id: project_id}
  end

  test "emits nothing and exits 0 when the service is unreachable" do
    stub(MemoryClient, :health, fn _ -> {:error, :econnrefused} end)
    reject(&MemoryClient.start_session/3)

    stdout = capture_io(fn -> assert SessionStart.run() == 0 end)
    assert stdout == ""
  end

  test "uses the session primer when summaries are enabled", %{project_id: project_id} do
    stub_full_setup(project_id, "sess-1")
    stub(MemoryClient, :summaries_status, fn _ -> {:ok, %{"enabled" => true}} end)

    primer = """
    Welcome back.

    ### Memory 2026-04-27 fact one
    ### Memory 2026-04-27 fact two
    """

    expect(MemoryClient, :session_primer, fn ^project_id, [] ->
      {:ok, %{"format" => "markdown", "content" => primer}}
    end)

    reject(&MemoryClient.latest_memories/4)

    stdout = capture_io(fn -> assert SessionStart.run() == 0 end)

    assert {:ok, "sess-1"} = SessionFile.read(project_id)
    payload = Jason.decode!(stdout)
    assert payload["hookSpecificOutput"]["hookEventName"] == "SessionStart"
    assert payload["hookSpecificOutput"]["additionalContext"] == primer
    assert payload["systemMessage"] =~ "primed session context (2 recent memories)"
  end

  test "falls back to latest-memories when summaries are disabled", %{project_id: project_id} do
    stub_full_setup(project_id, "sess-2")
    stub(MemoryClient, :summaries_status, fn _ -> {:error, {:status, 503, %{}}} end)

    latest = """
    ### Memory 1
    body 1

    ### Memory 2
    body 2

    ### Memory 3
    body 3
    """

    expect(MemoryClient, :latest_memories, fn ^project_id, 100, :markdown, [] ->
      {:ok, %{"format" => "markdown", "content" => latest}}
    end)

    reject(&MemoryClient.session_primer/2)

    stdout = capture_io(fn -> assert SessionStart.run() == 0 end)
    payload = Jason.decode!(stdout)

    additional = payload["hookSpecificOutput"]["additionalContext"]
    assert additional =~ "## Previous Gingko Memories"
    assert additional =~ latest
    assert additional =~ "gingko memory append-step"
    assert additional =~ "gingko-memory"

    assert payload["systemMessage"] =~ "Loaded 3 recent memories into session context"
  end

  test "emits no JSON when both priming sources return empty content", %{project_id: project_id} do
    stub_full_setup(project_id, "sess-3")
    stub(MemoryClient, :summaries_status, fn _ -> {:error, {:status, 503, %{}}} end)
    stub(MemoryClient, :latest_memories, fn _, _, _, _ -> {:ok, %{"content" => ""}} end)

    stdout = capture_io(fn -> assert SessionStart.run() == 0 end)
    assert stdout == ""
  end

  test "still records the session pointer even if priming fails", %{project_id: project_id} do
    stub_full_setup(project_id, "sess-4")
    stub(MemoryClient, :summaries_status, fn _ -> {:error, :unreachable} end)
    stub(MemoryClient, :latest_memories, fn _, _, _, _ -> {:error, :timeout} end)

    capture_io(fn -> SessionStart.run() end)
    assert {:ok, "sess-4"} = SessionFile.read(project_id)
  end

  defp stub_full_setup(project_id, session_id) do
    stub(MemoryClient, :health, fn _ -> {:ok, %{"status" => "ok"}} end)
    stub(MemoryClient, :open_project, fn ^project_id, _ -> {:ok, %{"already_open" => false}} end)

    stub(MemoryClient, :start_session, fn ^project_id, _body, _ ->
      {:ok, %{"session_id" => session_id}}
    end)
  end
end
