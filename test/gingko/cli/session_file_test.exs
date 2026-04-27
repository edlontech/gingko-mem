defmodule Gingko.CLI.SessionFileTest do
  use ExUnit.Case, async: true

  alias Gingko.CLI.SessionFile

  setup do
    project_id = "sf-#{System.unique_integer([:positive])}"
    on_exit(fn -> SessionFile.clear(project_id) end)
    {:ok, project_id: project_id}
  end

  test "read returns :error when no pointer file exists", %{project_id: project_id} do
    assert SessionFile.read(project_id) == :error
  end

  test "write/read round-trip preserves the session id", %{project_id: project_id} do
    assert :ok = SessionFile.write(project_id, "session-abc")
    assert {:ok, "session-abc"} = SessionFile.read(project_id)
  end

  test "trims whitespace and treats empty contents as missing", %{project_id: project_id} do
    File.write!(SessionFile.path(project_id), "")
    assert SessionFile.read(project_id) == :error

    File.write!(SessionFile.path(project_id), "session-xyz\n")
    assert {:ok, "session-xyz"} = SessionFile.read(project_id)
  end

  test "clear removes the pointer file and is idempotent", %{project_id: project_id} do
    SessionFile.write(project_id, "session-abc")
    assert :ok = SessionFile.clear(project_id)
    refute File.exists?(SessionFile.path(project_id))
    assert :ok = SessionFile.clear(project_id)
  end

  test "path/1 lives under the system temp directory", %{project_id: project_id} do
    path = SessionFile.path(project_id)
    assert path |> Path.dirname() |> Path.expand() == System.tmp_dir!() |> Path.expand()
    assert path |> Path.basename() == "gingko-session-#{project_id}"
  end
end
