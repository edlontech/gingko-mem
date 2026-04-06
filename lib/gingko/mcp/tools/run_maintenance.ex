defmodule Gingko.MCP.Tools.RunMaintenance do
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "run_maintenance"

  def description do
    """
    Trigger an async graph maintenance operation on a project. \
    Operations run in the background; results arrive via notifier events.

    Available operations:
    - "decay": prune low-utility nodes by recency, frequency, and reward scoring
    - "consolidate": deduplicate near-similar semantic nodes via embedding comparison
    - "validate": penalize abstract nodes with weak episodic provenance grounding
    """
  end

  @valid_operations ["decay", "consolidate", "validate"]

  schema do
    field(:project_id, :string,
      required: true,
      description: "The project identifier."
    )

    field(:operation, :string,
      required: true,
      description: ~s(One of "decay", "consolidate", or "validate".)
    )
  end

  def execute(args, frame) do
    project_id = args[:project_id] || args["project_id"]
    operation = args[:operation] || args["operation"]

    if operation in @valid_operations do
      result =
        Gingko.Memory.run_maintenance(%{
          project_id: project_id,
          operation: String.to_existing_atom(operation)
        })

      ToolResponse.from_result(result, frame)
    else
      ToolResponse.from_result(
        {:error,
         %{
           code: :invalid_operation,
           message: "must be one of: #{Enum.join(@valid_operations, ", ")}"
         }},
        frame
      )
    end
  end
end
