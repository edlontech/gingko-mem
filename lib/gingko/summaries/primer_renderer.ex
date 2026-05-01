defmodule Gingko.Summaries.PrimerRenderer do
  @moduledoc """
  Composes the four session-primer regions (playbook, charter, summary, recent
  memories) into a single markdown document.

  Region boundaries are marked with stable `<!-- region:kind -->` /
  `<!-- /region:kind -->` comments so downstream tooling can target sections
  without reparsing prose.
  """

  alias Gingko.Memory.MarkdownRenderer
  alias Gingko.Summaries.PrincipalMemorySection

  @playbook """
  # Gingko Memory — Recall Playbook

  Use the gingko MCP tools to recall and record memory:

  - `recall(project_id, query)` — semantic search across raw memories.
  - `latest_memories(project_id, top_k)` — the most recent memories.
  - `get_node(project_id, node_id)` — drill into a single memory and its neighbors.
  - `append_step(session_id, observation, action)` — record what you observed and did.

  Read the project charter (if present) and the project summary below for
  durable context, then use `recall` for specifics. Append steps as you
  work; the summary regenerates automatically.
  """

  @type summary_section ::
          PrincipalMemorySection.t() | %{content: String.t(), updated_at: DateTime.t()} | nil

  @spec render(
          charter :: String.t() | nil,
          summary :: summary_section(),
          recent_memories :: [map()]
        ) :: String.t()
  def render(charter, summary, recent_memories) do
    [
      region(:playbook, @playbook),
      region(:charter, charter_body(charter)),
      region(:summary, summary_body(summary)),
      region(:recent_memories, recent_memories_body(recent_memories))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp region(_, nil), do: nil

  defp region(kind, body) do
    "<!-- region:#{kind} -->\n#{body}\n<!-- /region:#{kind} -->"
  end

  defp charter_body(nil), do: nil
  defp charter_body(""), do: nil
  defp charter_body(content) when is_binary(content), do: "# Project Charter\n\n#{content}"

  defp summary_body(nil), do: "# Project Summary\n\n_Not yet generated._"
  defp summary_body(%{content: ""}), do: "# Project Summary\n\n_Not yet generated._"

  defp summary_body(%{content: content, updated_at: %DateTime{} = updated_at}) do
    "# Project Summary — updated #{DateTime.to_iso8601(updated_at)}\n\n#{content}"
  end

  defp summary_body(%{content: content}) do
    "# Project Summary\n\n#{content}"
  end

  defp recent_memories_body([]), do: "# Recent Memories\n\n_No recent memories._"

  defp recent_memories_body(memories) when is_list(memories) do
    "# Recent Memories\n\n#{MarkdownRenderer.render(memories)}"
  end
end
