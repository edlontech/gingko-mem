defmodule Gingko.CLI.MemoryTest do
  use ExUnit.Case, async: true
  use Mimic

  import ExUnit.CaptureIO

  alias Gingko.CLI.Memory
  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  setup do
    Mimic.copy(MemoryClient)
    Mimic.copy(ProjectId)

    project_id = "memtest-#{System.unique_integer([:positive])}"
    stub(ProjectId, :detect, fn -> project_id end)

    on_exit(fn -> SessionFile.clear(project_id) end)

    {:ok, project_id: project_id}
  end

  describe "project-id" do
    test "prints the detected project id", %{project_id: project_id} do
      stdout = capture_io(fn -> assert Memory.run("project-id", []) == 0 end)
      assert stdout == "#{project_id}\n"
    end
  end

  describe "session-id" do
    test "is silent when no session file exists" do
      stdout = capture_io(fn -> assert Memory.run("session-id", []) == 0 end)
      assert stdout == ""
    end

    test "prints the session id when present", %{project_id: project_id} do
      :ok = SessionFile.write(project_id, "sess-77")
      stdout = capture_io(fn -> assert Memory.run("session-id", []) == 0 end)
      assert stdout == "sess-77\n"
    end
  end

  describe "ensure-project" do
    test "POSTs open and prints the response body", %{project_id: project_id} do
      expect(MemoryClient, :open_project, fn ^project_id, [] ->
        {:ok, %{"project_id" => project_id, "already_open" => false}}
      end)

      stdout = capture_io(fn -> assert Memory.run("ensure-project", []) == 0 end)
      assert Jason.decode!(stdout) == %{"project_id" => project_id, "already_open" => false}
    end

    test "warns and exits 0 on transport error" do
      stub(MemoryClient, :open_project, fn _, _ -> {:error, :econnrefused} end)

      stderr = capture_io(:stderr, fn -> assert Memory.run("ensure-project", []) == 0 end)
      assert stderr =~ "ensure-project failed"
    end
  end

  describe "start-session" do
    test "uses the default goal when none is supplied", %{project_id: project_id} do
      expect(MemoryClient, :start_session, fn ^project_id, body, [] ->
        assert body == %{goal: "Claude Code session", agent: "claude-code"}
        {:ok, %{"session_id" => "sess-1"}}
      end)

      capture_io(fn -> assert Memory.run("start-session", []) == 0 end)
      assert {:ok, "sess-1"} = SessionFile.read(project_id)
    end

    test "uses the supplied goal", %{project_id: project_id} do
      expect(MemoryClient, :start_session, fn ^project_id,
                                              %{goal: "fix flaky test"} = _body,
                                              [] ->
        {:ok, %{"session_id" => "sess-2"}}
      end)

      stdout = capture_io(fn -> assert Memory.run("start-session", ["fix flaky test"]) == 0 end)
      assert Jason.decode!(stdout) == %{"session_id" => "sess-2"}
    end

    test "skips writing the session file when the API does not return one", %{
      project_id: project_id
    } do
      stub(MemoryClient, :start_session, fn _, _, _ -> {:ok, %{"queued" => true}} end)

      capture_io(fn -> assert Memory.run("start-session", []) == 0 end)
      assert SessionFile.read(project_id) == :error
    end
  end

  describe "append-step" do
    test "is a silent no-op when no session exists" do
      reject(&MemoryClient.append_step/4)

      stdout = capture_io(fn -> assert Memory.run("append-step", ["obs", "act"]) == 0 end)
      assert stdout == ""
    end

    test "POSTs the step when a session exists", %{project_id: project_id} do
      :ok = SessionFile.write(project_id, "sess-9")

      expect(MemoryClient, :append_step, fn "sess-9", "obs", "act", [] ->
        {:ok, %{"accepted" => true}}
      end)

      stdout = capture_io(fn -> assert Memory.run("append-step", ["obs", "act"]) == 0 end)
      assert Jason.decode!(stdout) == %{"accepted" => true}
    end
  end

  describe "close-session" do
    test "is a silent no-op when no session exists" do
      reject(&MemoryClient.commit_session/2)
      assert Memory.run("close-session", []) == 0
    end

    test "POSTs commit and clears the session file", %{project_id: project_id} do
      :ok = SessionFile.write(project_id, "sess-10")

      expect(MemoryClient, :commit_session, fn "sess-10", [] ->
        {:ok, %{"state" => "closing"}}
      end)

      stdout = capture_io(fn -> assert Memory.run("close-session", []) == 0 end)
      assert Jason.decode!(stdout) == %{"state" => "closing"}
      assert SessionFile.read(project_id) == :error
    end

    test "still clears the session file on transport failure", %{project_id: project_id} do
      :ok = SessionFile.write(project_id, "sess-11")
      stub(MemoryClient, :commit_session, fn _, _ -> {:error, :econnrefused} end)

      capture_io(:stderr, fn -> assert Memory.run("close-session", []) == 0 end)
      assert SessionFile.read(project_id) == :error
    end
  end

  describe "recall / get-node / session-primer" do
    test "recall passes the query through", %{project_id: project_id} do
      expect(MemoryClient, :recall, fn ^project_id, "auth bug", [] ->
        {:ok, %{"matches" => []}}
      end)

      stdout = capture_io(fn -> assert Memory.run("recall", ["auth bug"]) == 0 end)
      assert Jason.decode!(stdout) == %{"matches" => []}
    end

    test "get-node prints the response body", %{project_id: project_id} do
      expect(MemoryClient, :get_node, fn ^project_id, "node-1", [] ->
        {:ok, %{"node" => %{"id" => "node-1"}}}
      end)

      stdout = capture_io(fn -> assert Memory.run("get-node", ["node-1"]) == 0 end)
      assert Jason.decode!(stdout) == %{"node" => %{"id" => "node-1"}}
    end

    test "session-primer prints the response body", %{project_id: project_id} do
      expect(MemoryClient, :session_primer, fn ^project_id, [] ->
        {:ok, %{"format" => "markdown", "content" => "## Primer"}}
      end)

      stdout = capture_io(fn -> assert Memory.run("session-primer", []) == 0 end)
      assert Jason.decode!(stdout)["content"] == "## Primer"
    end
  end

  describe "latest-memories" do
    test "defaults top_k to 30 and uses :json format" do
      expect(MemoryClient, :latest_memories, fn _project_id, 30, :json, [] ->
        {:ok, %{"memories" => []}}
      end)

      stdout = capture_io(fn -> assert Memory.run("latest-memories", []) == 0 end)
      assert Jason.decode!(stdout) == %{"memories" => []}
    end

    test "honours an explicit top_k" do
      expect(MemoryClient, :latest_memories, fn _, 100, :json, [] ->
        {:ok, %{"memories" => []}}
      end)

      capture_io(fn -> assert Memory.run("latest-memories", ["100"]) == 0 end)
    end

    test "falls back to the default when top_k is unparseable" do
      expect(MemoryClient, :latest_memories, fn _, 30, :json, [] -> {:ok, %{"memories" => []}} end)

      capture_io(fn -> assert Memory.run("latest-memories", ["abc"]) == 0 end)
    end

    test "latest-memories-md uses :markdown format" do
      expect(MemoryClient, :latest_memories, fn _, 30, :markdown, [] ->
        {:ok, %{"format" => "markdown", "content" => "# memories"}}
      end)

      stdout = capture_io(fn -> assert Memory.run("latest-memories-md", []) == 0 end)
      assert Jason.decode!(stdout)["format"] == "markdown"
    end
  end

  describe "summaries-enabled" do
    test "returns 0 when enabled" do
      stub(MemoryClient, :summaries_status, fn _opts -> {:ok, %{"enabled" => true}} end)
      assert Memory.run("summaries-enabled", []) == 0
    end

    test "returns 1 when disabled" do
      stub(MemoryClient, :summaries_status, fn _opts -> {:error, {:status, 503, %{}}} end)
      assert Memory.run("summaries-enabled", []) == 1
    end

    test "is silent on stdout in both cases" do
      stub(MemoryClient, :summaries_status, fn _opts -> {:ok, %{"enabled" => true}} end)
      assert capture_io(fn -> Memory.run("summaries-enabled", []) end) == ""
    end
  end

  describe "status" do
    test "returns 0 and prints a reachable message when /health responds" do
      stub(MemoryClient, :health, fn _opts -> {:ok, %{"status" => "ok"}} end)

      stdout = capture_io(fn -> assert Memory.run("status", []) == 0 end)
      assert stdout =~ "Gingko reachable at"
    end

    test "returns 1 on transport failure" do
      stub(MemoryClient, :health, fn _opts -> {:error, :econnrefused} end)
      assert Memory.run("status", []) == 1
    end
  end

  describe "unknown command" do
    test "warns and returns 1" do
      stderr =
        capture_io(:stderr, fn -> capture_io(fn -> assert Memory.run("nope", []) == 1 end) end)

      assert stderr =~ "unknown memory subcommand"
    end
  end
end
