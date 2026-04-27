defmodule Gingko.CLI.Hook.SessionEndTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Gingko.CLI.Hook.SessionEnd
  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  setup do
    Mimic.copy(MemoryClient)
    Mimic.copy(ProjectId)

    project_id = "ssend-#{System.unique_integer([:positive])}"
    stub(ProjectId, :detect, fn -> project_id end)

    on_exit(fn -> SessionFile.clear(project_id) end)
    {:ok, project_id: project_id}
  end

  test "is a no-op when no session pointer exists" do
    reject(&MemoryClient.commit_session/2)
    assert SessionEnd.run() == 0
  end

  test "commits the existing session and clears the pointer", %{project_id: project_id} do
    :ok = SessionFile.write(project_id, "sess-end-1")

    expect(MemoryClient, :commit_session, fn "sess-end-1", [] ->
      {:ok, %{"state" => "closing"}}
    end)

    assert SessionEnd.run() == 0
    assert SessionFile.read(project_id) == :error
  end

  test "still clears the pointer when the commit fails", %{project_id: project_id} do
    :ok = SessionFile.write(project_id, "sess-end-2")
    stub(MemoryClient, :commit_session, fn _, _ -> {:error, :econnrefused} end)

    assert SessionEnd.run() == 0
    assert SessionFile.read(project_id) == :error
  end
end
