defmodule Gingko.Summaries.ClusterSummarizer do
  @moduledoc """
  LLM-backed summarizer for a single cluster. Produces a one-line `headline`,
  a markdown `content` body, and a free-form `frontmatter` map. The caller
  (`Gingko.Summaries.ClusterWorker`) decides whether to rebuild incrementally
  (previous summary + new memories) or from scratch (full memory set).
  """

  alias Sycophant.Message

  @schema Zoi.map(
            %{
              headline: Zoi.string(),
              content: Zoi.string(),
              frontmatter:
                Zoi.map(
                  %{
                    subtopics: Zoi.array(Zoi.string()),
                    key_entities: Zoi.array(Zoi.string())
                  },
                  coerce: true
                )
            },
            coerce: true
          )

  @system """
  You maintain a cluster summary for a Gingko project. Produce a one-line
  headline (max 120 characters) describing the cluster's current theme, and a
  150-400 word markdown body that synthesizes the memories. No boilerplate, no
  meta-commentary. Respond as a JSON object with keys `headline`, `content`,
  and `frontmatter`. The `frontmatter` object has two array fields:

    - `subtopics`: short labels for finer-grained themes within the cluster
      (the cluster itself is already named by its tag, so do not repeat it).
    - `key_entities`: named entities, modules, files, or recurring concepts
      worth indexing.

  Use empty arrays when nothing fits.
  """

  @spec summarize(Gingko.Summaries.ClusterSummary.t(), [map()], :incremental | :full) ::
          {:ok, %{headline: String.t(), content: String.t(), frontmatter: map()}}
          | {:error, term()}
  def summarize(cluster, memories, mode) when mode in [:incremental, :full] do
    messages = [
      Message.system(@system),
      Message.user(build_prompt(cluster, memories, mode))
    ]

    case Sycophant.generate_object(llm_model(), messages, @schema) do
      {:ok, %{object: %{headline: headline, content: content, frontmatter: frontmatter}}} ->
        {:ok, %{headline: headline, content: content, frontmatter: frontmatter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(cluster, memories, :incremental) do
    """
    Tag: #{cluster.tag_label}

    Previous summary:
    #{cluster.content}

    New memories since last summary:
    #{format_memories(memories)}

    Rewrite the summary to incorporate the new memories. Keep prior insights
    that remain relevant; drop details the new memories supersede.
    """
  end

  defp build_prompt(cluster, memories, :full) do
    """
    Tag: #{cluster.tag_label}

    Full memory set:
    #{format_memories(memories)}

    Produce a fresh summary of the cluster from the full memory set.
    """
  end

  defp format_memories([]), do: "(no memories)"

  defp format_memories(memories) do
    Enum.map_join(memories, "\n", &format_memory/1)
  end

  defp format_memory(%{node: node}), do: "- #{memory_body(node)}"
  defp format_memory(other), do: "- #{inspect(other)}"

  defp memory_body(%{proposition: p}) when is_binary(p), do: p

  defp memory_body(%{observation: o, action: a}) when is_binary(o) and is_binary(a),
    do: "#{o} -> #{a}"

  defp memory_body(%{content: c}) when is_binary(c), do: c
  defp memory_body(other), do: inspect(other, limit: :infinity)

  defp llm_model do
    :gingko
    |> Application.fetch_env!(Gingko.Memory)
    |> Keyword.fetch!(:mnemosyne_config)
    |> Map.fetch!(:llm)
    |> Map.fetch!(:model)
  end
end
