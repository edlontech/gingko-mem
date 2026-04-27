defmodule Gingko.CLI.Hook.SessionStopTest do
  use ExUnit.Case, async: true
  use Mimic

  import ExUnit.CaptureIO

  alias Gingko.CLI.Hook.SessionStop
  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  @moduletag :tmp_dir

  setup do
    Mimic.copy(MemoryClient)
    Mimic.copy(ProjectId)

    project_id = "ssstop-#{System.unique_integer([:positive])}"
    stub(ProjectId, :detect, fn -> project_id end)

    on_exit(fn -> SessionFile.clear(project_id) end)
    {:ok, project_id: project_id}
  end

  test "always emits the bail JSON, even when the service is unreachable", %{tmp_dir: tmp_dir} do
    stub(MemoryClient, :health, fn _ -> {:error, :econnrefused} end)
    reject(&MemoryClient.summarize_session/3)

    transcript = Path.join(tmp_dir, "transcript.jsonl")
    File.write!(transcript, "ignored")

    stdout = run_with_input(transcript_payload(transcript))
    assert Jason.decode!(stdout) == %{"continue" => true, "suppressOutput" => true}
  end

  test "tails the last 8KB of the transcript and POSTs to the existing session", %{
    project_id: project_id,
    tmp_dir: tmp_dir
  } do
    :ok = SessionFile.write(project_id, "sess-existing")
    stub(MemoryClient, :health, fn _ -> {:ok, %{}} end)

    transcript = Path.join(tmp_dir, "transcript.jsonl")
    head_padding = String.duplicate("X", 9_000)
    tail_marker = "TAIL_MARKER_VISIBLE"
    File.write!(transcript, head_padding <> tail_marker)

    expect(MemoryClient, :summarize_session, fn "sess-existing", content, [] ->
      assert byte_size(content) == 8_000
      assert String.ends_with?(content, tail_marker)
      {:ok, %{"summarized" => true}}
    end)

    stdout = run_with_input(transcript_payload(transcript))
    assert Jason.decode!(stdout) == %{"continue" => true, "suppressOutput" => true}
  end

  test "auto-creates a session when no pointer exists and POSTs the summary", %{
    project_id: project_id,
    tmp_dir: tmp_dir
  } do
    stub(MemoryClient, :health, fn _ -> {:ok, %{}} end)
    stub(MemoryClient, :open_project, fn ^project_id, _ -> {:ok, %{}} end)

    expect(MemoryClient, :start_session, fn ^project_id, %{goal: goal}, _ ->
      assert goal =~ "auto-created on stop"
      {:ok, %{"session_id" => "sess-fresh"}}
    end)

    expect(MemoryClient, :summarize_session, fn "sess-fresh", _content, [] ->
      {:ok, %{"summarized" => true}}
    end)

    transcript = Path.join(tmp_dir, "transcript.jsonl")
    File.write!(transcript, "fresh transcript content")

    stdout = run_with_input(transcript_payload(transcript))
    assert Jason.decode!(stdout) == %{"continue" => true, "suppressOutput" => true}
    assert {:ok, "sess-fresh"} = SessionFile.read(project_id)
  end

  test "falls back to auto-create when the existing session refuses the summary", %{
    project_id: project_id,
    tmp_dir: tmp_dir
  } do
    :ok = SessionFile.write(project_id, "sess-stale")

    stub(MemoryClient, :health, fn _ -> {:ok, %{}} end)
    stub(MemoryClient, :open_project, fn _, _ -> {:ok, %{}} end)

    Mimic.expect(MemoryClient, :summarize_session, fn "sess-stale", _content, _ ->
      {:error, {:status, 410, %{"reason" => "session closed"}}}
    end)

    Mimic.expect(MemoryClient, :start_session, fn _, _, _ ->
      {:ok, %{"session_id" => "sess-replacement"}}
    end)

    Mimic.expect(MemoryClient, :summarize_session, fn "sess-replacement", _content, _ ->
      {:ok, %{}}
    end)

    transcript = Path.join(tmp_dir, "transcript.jsonl")
    File.write!(transcript, "stale-then-fresh")

    run_with_input(transcript_payload(transcript))

    assert {:ok, "sess-replacement"} = SessionFile.read(project_id)
  end

  test "skips the API entirely when stdin has no transcript path", %{tmp_dir: _tmp_dir} do
    stub(MemoryClient, :health, fn _ -> {:ok, %{}} end)
    reject(&MemoryClient.summarize_session/3)
    reject(&MemoryClient.start_session/3)

    stdout = run_with_input("{}")
    assert Jason.decode!(stdout) == %{"continue" => true, "suppressOutput" => true}
  end

  test "skips the API when the transcript file is missing" do
    stub(MemoryClient, :health, fn _ -> {:ok, %{}} end)
    reject(&MemoryClient.summarize_session/3)

    stdout = run_with_input(transcript_payload("/nonexistent/transcript.jsonl"))
    assert Jason.decode!(stdout) == %{"continue" => true, "suppressOutput" => true}
  end

  defp transcript_payload(path), do: Jason.encode!(%{transcript_path: path})

  defp run_with_input(input) do
    capture_io(input, fn -> assert SessionStop.run() == 0 end)
  end
end
