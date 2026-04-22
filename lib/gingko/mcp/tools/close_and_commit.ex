defmodule Gingko.MCP.Tools.CloseAndCommit do
  @moduledoc """
  MCP tool that closes an active session and asynchronously commits its
  accumulated steps to the knowledge graph. Returns as soon as the close is
  queued; extraction and commit run in the background. Sessions auto-commit
  when they end naturally, so this is only needed to force an early flush
  mid-workflow (for example, before a long-running operation or context switch).
  """
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "close_async"

  def description do
    """
    Close a session and asynchronously commit its steps to the knowledge graph. \
    Returns immediately after queuing the close operation — extraction and commit \
    happen in the background. You normally do NOT need to call this — sessions \
    auto-commit when they end naturally. Use only when you want to explicitly \
    flush accumulated knowledge mid-workflow, e.g. before a long-running operation \
    or when switching context.
    """
  end

  schema do
    field(:session_id, :string,
      required: true,
      description: "The session to close and commit asynchronously."
    )
  end

  def execute(args, frame) do
    session_id = args[:session_id] || args["session_id"]
    ToolResponse.from_result(Gingko.Memory.close_async(%{session_id: session_id}), frame)
  end
end
