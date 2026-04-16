defmodule Gingko.Summaries.PrimerRenderer do
  @moduledoc """
  Composes the five session-primer regions (playbook, charter, state,
  cluster index, recent memories) into a single markdown document.

  Region boundaries are marked with stable `<!-- region:kind -->` /
  `<!-- /region:kind -->` comments so downstream tooling can target sections
  without reparsing prose.
  """

  alias Gingko.Memory.MarkdownRenderer
  alias Gingko.Summaries.ClusterSummary
  alias Gingko.Summaries.PrincipalMemorySection

  @type state_section ::
          PrincipalMemorySection.t() | %{content: String.t(), updated_at: DateTime.t()} | nil

  @spec render(
          playbook :: String.t(),
          charter :: String.t() | nil,
          state :: state_section(),
          clusters :: [ClusterSummary.t()],
          recent_memories :: [map()]
        ) :: String.t()
  def render(playbook, charter, state, clusters, recent_memories) do
    [
      region(:playbook, playbook),
      region(:charter, charter_body(charter)),
      region(:state, state_body(state)),
      region(:cluster_index, cluster_index_body(clusters)),
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

  defp state_body(nil), do: "# Project State\n\n_Not yet generated._"
  defp state_body(%{content: ""}), do: "# Project State\n\n_Not yet generated._"

  defp state_body(%{content: content, updated_at: %DateTime{} = updated_at}) do
    "# Project State — updated #{DateTime.to_iso8601(updated_at)}\n\n#{content}"
  end

  defp state_body(%{content: content}) do
    "# Project State\n\n#{content}"
  end

  defp cluster_index_body([]), do: "# Cluster Index\n\n_No clusters yet._"

  defp cluster_index_body(clusters) do
    visible = Enum.reject(clusters, & &1.locked)

    case visible do
      [] ->
        "# Cluster Index\n\n_No clusters yet._"

      rows ->
        lines = Enum.map(rows, &cluster_line/1)

        "# Cluster Index\n\n" <>
          Enum.join(lines, "\n") <>
          "\n\nUse `get_cluster(slug)` to expand any of these."
    end
  end

  defp cluster_line(%ClusterSummary{} = c) do
    headline = c.headline || "(no headline yet)"

    "- **#{c.slug}** (#{c.memory_count} memories, updated #{relative_time(c.last_generated_at)}) — #{headline}"
  end

  defp recent_memories_body([]), do: "# Recent Memories\n\n_No recent memories._"

  defp recent_memories_body(memories) when is_list(memories) do
    "# Recent Memories\n\n#{MarkdownRenderer.render(memories)}"
  end

  defp relative_time(nil), do: "never"

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
