defmodule Gingko.MCP.Tools.LatestMemories do
  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse

  def name, do: "latest_memories"

  def description do
    """
    Fetch the most recently created memories from a project's knowledge graph, \
    sorted newest first. Useful for reviewing what the agent has learned recently \
    without a specific search query.
    """
  end

  schema do
    field(:project_id, :string,
      required: true,
      description: "The project whose recent memories to fetch."
    )

    field(:top_k, :integer, description: "Maximum number of memories to return. Defaults to 10.")

    field(:types, {:array, :string},
      description:
        "Node types to include (e.g. [\"semantic\", \"episodic\"]). Defaults to semantic and episodic."
    )

    field(:format, :string,
      description:
        "Output format: \"json\" (default) or \"markdown\" for a human-readable document."
    )
  end

  def execute(args, frame) do
    format = args[:format] || args["format"]

    attrs = %{
      project_id: args[:project_id] || args["project_id"],
      top_k: args[:top_k] || args["top_k"],
      types: parse_types(args[:types] || args["types"])
    }

    attrs =
      attrs
      |> maybe_drop(:top_k)
      |> maybe_drop(:types)

    case {Gingko.Memory.latest_memories(attrs), format} do
      {{:ok, result}, "markdown"} ->
        result.memories
        |> Gingko.Memory.MarkdownRenderer.render()
        |> ToolResponse.from_text(frame)

      {result, _} ->
        ToolResponse.from_result(result, frame)
    end
  end

  defp parse_types(nil), do: nil
  defp parse_types(types) when is_list(types), do: Enum.map(types, &String.to_existing_atom/1)

  defp maybe_drop(attrs, key) do
    if Map.get(attrs, key), do: attrs, else: Map.delete(attrs, key)
  end
end
