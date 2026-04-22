defmodule Gingko.MCP.Tools.AppendStep do
  @moduledoc """
  MCP tool that records a single observation/action pair into the active memory
  session. Steps are the atomic units of memory: one observation (context,
  findings, state) paired with the action taken in response. Called repeatedly
  during a session, once per meaningful decision point.
  """
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "append_step"

  def description do
    """
    Record a single observation/action pair to the current session. Each step captures what \
    was observed (context, findings, state) and what action was taken in response. Steps are \
    the atomic units of memory — call this for each meaningful decision point during your work.
    """
  end

  schema do
    field(:session_id, :string, required: true, description: "The active session to append to.")

    field(:observation, :string,
      required: true,
      description:
        "What was observed: relevant context, findings, current state, or problem description."
    )

    field(:action, :string,
      required: true,
      description:
        "What was done in response: decision made, code written, approach chosen, or conclusion reached."
    )
  end

  def execute(args, frame) do
    ToolResponse.from_result(
      Gingko.Memory.append_step(%{
        session_id: args[:session_id] || args["session_id"],
        observation: args[:observation] || args["observation"],
        action: args[:action] || args["action"]
      }),
      frame
    )
  end
end
