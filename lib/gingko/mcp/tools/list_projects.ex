defmodule Gingko.MCP.Tools.ListProjects do
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "list_projects"

  def description do
    """
    List all projects that have been registered with Gingko. Returns project identifiers \
    and metadata. Use this to discover available projects before opening one.
    """
  end

  schema do
  end

  def execute(_args, frame) do
    ToolResponse.from_result({:ok, Gingko.Memory.list_projects()}, frame)
  end
end
