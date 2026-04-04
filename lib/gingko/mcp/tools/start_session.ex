defmodule Gingko.MCP.Tools.StartSession do
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "start_session"

  def description do
    """
    Begin a new memory session within a project. A session groups related observation/action \
    steps under a single goal. Call open_project_memory first. When the session ends, accumulated \
    steps are automatically committed to the knowledge graph — you do not need to call \
    close_async unless you want to force an early commit.
    """
  end

  schema do
    field(:project_id, :string,
      required: true,
      description:
        "The project to create the session in. Must already be opened via open_project_memory."
    )

    field(:goal, :string,
      required: true,
      description:
        "A concise description of what this session aims to accomplish. Used for retrieval and graph organization."
    )

    field(:agent, :string,
      description:
        "Identifier for the agent creating this session. Useful for multi-agent setups to track provenance."
    )

    field(:thread_id, :string,
      description:
        "External conversation or thread ID to correlate this session with its originating context."
    )
  end

  def execute(args, frame) do
    attrs = %{
      project_id: args[:project_id] || args["project_id"],
      goal: args[:goal] || args["goal"],
      agent: args[:agent] || args["agent"],
      thread_id: args[:thread_id] || args["thread_id"]
    }

    ToolResponse.from_result(Gingko.Memory.start_session(attrs), frame)
  end
end
