defmodule Gingko.CLI.Hook.SessionEnd do
  @moduledoc """
  Implements the Claude Code SessionEnd hook.

  Replays `plugins/claude_code/hooks/scripts/session-end.sh` by closing
  the active session pointer and wiping the on-disk marker. The bash
  script backgrounded the call to keep the hook fast, but a single HTTP
  POST is millisecond-scale, so we run it synchronously and avoid the
  process-fork tax.
  """

  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  @spec run() :: 0
  def run do
    project_id = ProjectId.detect()

    case SessionFile.read(project_id) do
      {:ok, session_id} ->
        _ = MemoryClient.commit_session(session_id, [])
        SessionFile.clear(project_id)

      :error ->
        :ok
    end

    0
  end
end
