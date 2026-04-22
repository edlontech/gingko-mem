defmodule Gingko.MCP.Tools.ListProjects do
  @moduledoc """
  MCP tool that lists every project registered with Gingko, returning the
  identifier and metadata for each. Typically the first call an agent makes to
  discover which project memories are available before opening one.
  """
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
