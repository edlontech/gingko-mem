defmodule Gingko.MCP.Tools.Recall do
  @moduledoc """
  MCP tool that searches a project's knowledge graph by semantic similarity,
  returning memories, observations, and actions from past sessions that match
  the query. The search can optionally be scoped to a specific session for
  tighter, context-local retrieval.
  """
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "recall"

  def description do
    """
    Search the project's knowledge graph using semantic similarity. Returns relevant \
    memories, observations, and actions from past sessions that match the query. Optionally \
    scope the search to a specific session for focused retrieval.
    """
  end

  schema do
    field(:project_id, :string,
      required: true,
      description: "The project whose memory graph to search."
    )

    field(:query, :string,
      required: true,
      description:
        "Natural language query describing what you want to remember. Be specific for better results."
    )

    field(:session_id, :string,
      description:
        "Optional. Restrict recall to a single session's context for focused retrieval."
    )
  end

  def execute(args, frame) do
    attrs = %{
      project_id: args[:project_id] || args["project_id"],
      query: args[:query] || args["query"],
      session_id: args[:session_id] || args["session_id"]
    }

    ToolResponse.from_result(Gingko.Memory.recall(attrs), frame)
  end
end
