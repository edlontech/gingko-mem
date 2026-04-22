defmodule Gingko.MCP.Tools.OpenProjectMemory do
  @moduledoc """
  MCP tool that initializes or reconnects to a project's memory graph. Must be
  called before any other memory operation for that project. Idempotent — safe
  to call multiple times — and returns the active repository handle.
  """
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "open_project_memory"

  def description do
    """
    Initialize or reconnect to a project's memory graph. Must be called before any other \
    memory operation for that project. Idempotent: safe to call multiple times. Returns the \
    active repository handle.
    """
  end

  schema do
    field(:project_id, :string,
      required: true,
      description: "The project folder name. Inherited from the working directory of the agent."
    )
  end

  def execute(args, frame) do
    project_id = args[:project_id] || args["project_id"]
    ToolResponse.from_result(Gingko.Memory.open_project(project_id), frame)
  end
end
