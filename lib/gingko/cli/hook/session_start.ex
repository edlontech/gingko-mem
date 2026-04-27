defmodule Gingko.CLI.Hook.SessionStart do
  @moduledoc """
  Implements the Claude Code SessionStart hook.

  Replays the flow previously expressed in
  `plugins/claude_code/hooks/scripts/session-start.sh`: open the project,
  start a fresh session, then prime the conversation with either the
  composed session primer (when the summaries feature is enabled) or the
  most recent 100 memories rendered as markdown. Emits a single JSON
  document on stdout matching the Claude Code hook contract:

      {
        "hookSpecificOutput": {
          "hookEventName": "SessionStart",
          "additionalContext": "...",
        },
        "systemMessage": "..."
      }

  Bails silently (no output, exit 0) when the Gingko service is
  unreachable or when there is no priming content to emit. Hooks must
  never block session start, so every failure mode falls through to
  exit 0.
  """

  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  @default_goal "Claude Code session"
  @latest_top_k 100

  @spec run() :: 0
  def run do
    case MemoryClient.health([]) do
      {:ok, _} -> prime()
      {:error, _} -> 0
    end
  end

  defp prime do
    project_id = ProjectId.detect()
    _ = MemoryClient.open_project(project_id, [])

    case MemoryClient.start_session(
           project_id,
           %{goal: @default_goal, agent: "claude-code"},
           []
         ) do
      {:ok, %{"session_id" => session_id}} when is_binary(session_id) ->
        :ok = SessionFile.write(project_id, session_id)

      _ ->
        :ok
    end

    case load_priming(project_id) do
      {:ok, content, mode} ->
        emit(content, mode)
        0

      :empty ->
        0
    end
  end

  defp load_priming(project_id) do
    if summaries_enabled?() do
      case MemoryClient.session_primer(project_id, []) do
        {:ok, %{"content" => content}} when is_binary(content) and content != "" ->
          {:ok, content, :primer}

        _ ->
          :empty
      end
    else
      case MemoryClient.latest_memories(project_id, @latest_top_k, :markdown, []) do
        {:ok, %{"content" => content}} when is_binary(content) and content != "" ->
          {:ok, content, :latest}

        _ ->
          :empty
      end
    end
  end

  defp summaries_enabled? do
    case MemoryClient.summaries_status([]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp emit(content, :primer) do
    write_output(
      content,
      "[gingko] primed session context (#{count_memories(content)} recent memories)"
    )
  end

  defp emit(content, :latest) do
    wrapped = wrap_latest_memories(content)

    write_output(
      wrapped,
      "[gingko] Loaded #{count_memories(content)} recent memories into session context"
    )
  end

  defp wrap_latest_memories(content) do
    """
    ## Previous Gingko Memories

    The following are your most recent memories from previous sessions in this project:

    #{content}

    Use `gingko memory append-step '<observation>' '<action>'` to record new memories during this session.

    IMPORTANT: You MUST invoke the `gingko-memory` skill at the start of this session to learn how to properly interact with the Gingko memory system.
    """
  end

  defp count_memories(content) do
    ~r/### Memory/
    |> Regex.scan(content)
    |> length()
  end

  defp write_output(context, message) do
    payload = %{
      hookSpecificOutput: %{
        hookEventName: "SessionStart",
        additionalContext: context
      },
      systemMessage: message
    }

    IO.puts(Jason.encode!(payload))
  end
end
