defmodule Gingko.MCP.Tools.GetSessionState do
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "get_session_state"

  def description do
    """
    Check a session's current lifecycle state (e.g. active, committed, idle). \
    Useful for verifying whether a session is still accepting steps or has already been committed.
    """
  end

  schema do
    field(:session_id, :string, required: true, description: "The session to inspect.")
  end

  def execute(args, frame) do
    session_id = args[:session_id] || args["session_id"]
    ToolResponse.from_result(Gingko.Memory.session_state(session_id), frame)
  end
end
