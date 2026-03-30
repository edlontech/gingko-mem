defmodule Gingko.Memory.MarkdownRenderer do
  @moduledoc """
  Renders serialized memory nodes as a Markdown document.
  """

  @spec render([map()]) :: String.t()
  def render([]), do: "No memories found."

  def render(memories) when is_list(memories) do
    memories
    |> Enum.map(&render_memory/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp render_memory(%{node: node, metadata: metadata}) do
    [
      heading(metadata),
      type_line(node),
      confidence_line(node),
      "",
      content(node)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp heading(%{created_at: created_at}) do
    "### Memory -- #{DateTime.to_iso8601(created_at)}"
  end

  defp type_line(%{type: type}) do
    "- **Type:** #{String.capitalize(type)}"
  end

  defp confidence_line(%{confidence: confidence}) when is_number(confidence) do
    "- **Confidence:** #{confidence}"
  end

  defp confidence_line(_), do: nil

  defp content(%{type: "semantic", proposition: proposition}), do: proposition

  defp content(%{type: "episodic"} = node) do
    Enum.reject(
      [
        field("Observation", node[:observation]),
        field("Action", node[:action])
      ],
      &is_nil/1
    )
  end

  defp content(%{type: "procedural"} = node) do
    Enum.reject(
      [
        field("Instruction", node[:instruction]),
        field("Condition", node[:condition]),
        field("Expected Outcome", node[:expected_outcome])
      ],
      &is_nil/1
    )
  end

  defp content(%{type: "intent", description: description}), do: description

  defp content(%{type: "subgoal"} = node) do
    lines = [node[:description]]

    case node[:parent_goal] do
      nil -> lines
      parent -> lines ++ [field("Parent Goal", parent)]
    end
  end

  defp content(%{type: "tag", label: label}), do: field("Label", label)

  defp content(%{type: "source"} = node) do
    Enum.reject(
      [
        field("Episode", node[:episode_id]),
        field("Step", node[:step_index])
      ],
      &is_nil/1
    )
  end

  defp content(_), do: nil

  defp field(_label, nil), do: nil
  defp field(label, value), do: "**#{label}:** #{value}"
end
