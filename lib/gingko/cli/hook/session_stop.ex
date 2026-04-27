defmodule Gingko.CLI.Hook.SessionStop do
  @moduledoc """
  Implements the Claude Code Stop hook.

  Replays `plugins/claude_code/hooks/scripts/session-stop.sh`: read the
  hook payload from stdin, tail the last 8 KB of the transcript, and POST
  it to the summarize endpoint. When the cached session pointer is
  missing or the targeted session refuses the summary the hook falls
  back to creating a fresh session and re-tries.

  Always emits `{"continue": true, "suppressOutput": true}` on stdout so
  Claude Code never blocks shutdown on hook failure.
  """

  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  @transcript_tail_bytes 8_000
  @auto_session_goal "Claude Code session (auto-created on stop)"

  @spec run() :: 0
  def run do
    try do
      case MemoryClient.health([]) do
        {:ok, _} -> attempt_summarize()
        {:error, _} -> :ok
      end
    after
      bail()
    end

    0
  end

  defp attempt_summarize do
    with {:ok, payload} <- read_stdin(),
         {:ok, transcript_path} <- extract_transcript_path(payload),
         {:ok, content} <- tail_transcript(transcript_path) do
      summarize(content)
    end
  end

  defp summarize(content) do
    project_id = ProjectId.detect()

    case SessionFile.read(project_id) do
      {:ok, session_id} ->
        case MemoryClient.summarize_session(session_id, content, []) do
          {:ok, _} -> :ok
          {:error, _} -> create_then_summarize(project_id, content)
        end

      :error ->
        create_then_summarize(project_id, content)
    end
  end

  defp create_then_summarize(project_id, content) do
    _ = MemoryClient.open_project(project_id, [])

    case MemoryClient.start_session(
           project_id,
           %{goal: @auto_session_goal, agent: "claude-code"},
           []
         ) do
      {:ok, %{"session_id" => session_id}} when is_binary(session_id) ->
        :ok = SessionFile.write(project_id, session_id)
        _ = MemoryClient.summarize_session(session_id, content, [])
        :ok

      _ ->
        :ok
    end
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      :eof -> :error
      {:error, _} -> :error
      "" -> :error
      data when is_binary(data) -> {:ok, data}
    end
  end

  defp extract_transcript_path(payload) do
    case Jason.decode(payload) do
      {:ok, %{"transcript_path" => path}} when is_binary(path) and path != "" -> {:ok, path}
      _ -> :error
    end
  end

  defp tail_transcript(path) do
    with {:ok, %{size: size}} when size > 0 <- File.stat(path),
         bytes = min(size, @transcript_tail_bytes),
         offset = size - bytes,
         {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      result =
        case :file.pread(fd, offset, bytes) do
          {:ok, data} when is_binary(data) and data != "" -> {:ok, data}
          _ -> :error
        end

      :file.close(fd)
      result
    else
      _ -> :error
    end
  end

  defp bail do
    IO.puts(Jason.encode!(%{continue: true, suppressOutput: true}))
  end
end
