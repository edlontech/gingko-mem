defmodule Gingko.MCP.Tools.CommitSession do
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "commit_session"

  def description do
    """
    Commit accumulated steps to the knowledge graph and immediately start a new session \
    for the same project. Use this to persist knowledge mid-workflow without losing your \
    session context — the new session continues with the same goal. Returns the new session_id.
    """
  end

  schema do
    field(:session_id, :string,
      required: true,
      description: "The current session to commit."
    )

    field(:project_id, :string,
      required: true,
      description: "The project the session belongs to."
    )

    field(:goal, :string,
      required: true,
      description: "The goal for the new session. Can be the same or updated."
    )

    field(:agent, :string,
      description: "Identifier for the agent. Carried over to the new session."
    )

    field(:thread_id, :string,
      description: "External thread ID. Carried over to the new session."
    )
  end

  def execute(args, frame) do
    attrs = %{
      session_id: args[:session_id] || args["session_id"],
      project_id: args[:project_id] || args["project_id"],
      goal: args[:goal] || args["goal"],
      agent: args[:agent] || args["agent"],
      thread_id: args[:thread_id] || args["thread_id"]
    }

    ToolResponse.from_result(Gingko.Memory.commit_session(attrs), frame)
  end
end
