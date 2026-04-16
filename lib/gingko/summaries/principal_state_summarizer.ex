defmodule Gingko.Summaries.PrincipalStateSummarizer do
  @moduledoc """
  LLM-backed summarizer that rolls all non-locked cluster headlines plus the
  optional project charter into a single project-level `state` document. Called
  by `Gingko.Summaries.PrincipalStateWorker` after any cluster regeneration.
  """

  alias Sycophant.Message

  @schema Zoi.map(
            %{
              content: Zoi.string(),
              frontmatter: Zoi.map(Zoi.string(), Zoi.any())
            },
            coerce: true
          )

  @system """
  You maintain the project-level memory document for a project. This is not a
  status report or a roadmap. It is the top tier of a long-term memory hierarchy
  that future agents read as their first source of enduring context about the
  project: its domain, architecture, vocabulary, constraints, decisions, and
  accumulated understanding.

  You are given the optional project charter (stable framing) and a list of
  cluster headlines (each a topic with accumulated observations underneath).
  Distill them into a 200-600 word markdown document of durable knowledge — the
  facts, decisions, mental models, and learned context that will still be true
  and useful many sessions from now.

  Write declaratively, in the present tense, as stored knowledge. Prefer:
    - what the project *is* and how its pieces fit together
    - established decisions and the reasoning behind them
    - constraints, invariants, and domain-specific conventions
    - recurring patterns, pitfalls, and non-obvious facts worth remembering
    - stable vocabulary and named concepts used across clusters

  Avoid forward-looking or status-report framing. Do not produce sections like
  "current focus", "next steps", "recent progress", "in progress", "todo",
  "open questions", "what to do next", or "roadmap". Do not hedge knowledge
  with temporal qualifiers ("recently", "currently", "as of now") unless the
  qualifier itself is load-bearing memory. If a cluster headline describes an
  in-flight task, extract the *durable learning* from it (the decision, the
  constraint, the fact) and record that — discard the task framing.

  Organize the content with short markdown headings that reflect topical areas
  drawn from the clusters, not a chronology. Keep prose tight; bullet lists
  where they aid recall.

  Respond as a JSON object with keys `content` (the markdown document) and
  `frontmatter` (an object; may be empty).
  """

  @spec summarize(
          [Gingko.Summaries.ClusterSummary.t()],
          Gingko.Summaries.PrincipalMemorySection.t() | nil
        ) :: {:ok, %{content: String.t(), frontmatter: map()}} | {:error, term()}
  def summarize(clusters, charter) when is_list(clusters) do
    messages = [
      Message.system(@system),
      Message.user(build_prompt(clusters, charter))
    ]

    case Sycophant.generate_object(llm_model(), messages, @schema) do
      {:ok, %{object: %{content: content, frontmatter: frontmatter}}} ->
        {:ok, %{content: content, frontmatter: frontmatter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(clusters, charter) do
    charter_section =
      case charter do
        %{content: content} when is_binary(content) and content != "" ->
          "Project charter:\n#{content}\n\n"

        _ ->
          ""
      end

    """
    #{charter_section}Cluster headlines:
    #{format_clusters(clusters)}

    Distill the durable knowledge across these clusters into the project memory document.
    """
  end

  defp format_clusters([]), do: "(no clusters yet)"

  defp format_clusters(clusters) do
    clusters
    |> Enum.map(fn c ->
      headline = c.headline || "(no headline yet)"
      "- #{c.tag_label} (#{c.memory_count} memories): #{headline}"
    end)
    |> Enum.join("\n")
  end

  defp llm_model do
    :gingko
    |> Application.fetch_env!(Gingko.Memory)
    |> Keyword.fetch!(:mnemosyne_config)
    |> Map.fetch!(:llm)
    |> Map.fetch!(:model)
  end
end
