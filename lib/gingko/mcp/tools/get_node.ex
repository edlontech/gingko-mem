defmodule Gingko.MCP.Tools.GetNode do
  @moduledoc """
  MCP tool that retrieves a single node from a project's knowledge graph along
  with its metadata and directly connected neighbors. Used to drill into a node
  returned by `recall`, or to traverse the graph by following links outward from
  a known node.
  """
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "get_node"

  def description do
    """
    Retrieve a specific node from the knowledge graph along with its metadata and \
    connected neighbors. Use this to drill into a particular memory node returned by \
    recall, or to traverse the graph by following links between nodes.
    """
  end

  schema do
    field(:project_id, :string, required: true, description: "The project containing the node.")

    field(:node_id, :string,
      required: true,
      description:
        "The unique identifier of the node to fetch. Typically obtained from a prior recall or get_node result."
    )
  end

  def execute(args, frame) do
    attrs = %{
      project_id: args[:project_id] || args["project_id"],
      node_id: args[:node_id] || args["node_id"]
    }

    ToolResponse.from_result(Gingko.Memory.get_node(attrs), frame)
  end
end
