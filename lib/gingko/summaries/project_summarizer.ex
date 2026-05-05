defmodule Gingko.Summaries.ProjectSummarizer do
  @moduledoc """
  LLM-backed summarizer that produces a single project-level "constitution"
  of durable knowledge — purpose, architecture, conventions, decisions —
  from semantic and episodic memories plus an optional charter. Called by
  `Gingko.Summaries.ProjectSummaryWorker` after any memory append.
  """

  alias Sycophant.Message

  @schema Zoi.map(
            %{
              content: Zoi.string(),
              frontmatter:
                Zoi.map(
                  %{
                    topics: Zoi.array(Zoi.string()),
                    key_concepts: Zoi.array(Zoi.string())
                  },
                  coerce: true
                )
            },
            coerce: true
          )

  @system """
  You maintain the project summary — a durable "constitution" of what this
  project IS, not what the user is doing right now. The summary is loaded
  at the start of every session as stable context. Recent activity is
  rendered separately by the system; do not duplicate it here.

  Write declaratively, in the present tense, as crystallized project
  knowledge. Avoid chronology. Forbidden phrasings include "recently",
  "the team has moved through", "has been", "iteratively", "several
  attempts", "has been updated to", and any narration of progress. State
  what is true now, not how it got there.

  Structure the response with these markdown sections, in order, omitting
  any section that has no durable content (do not invent filler):

    ## Purpose
    What the project is and the problem it solves. One short paragraph.

    ## Architecture & Conventions
    Modules, contexts, data flow, naming, patterns, vocabulary, and
    constraints that shape how code is written here. Bullet or short
    paragraphs. Reference concrete module / file names when stable.

    ## Key Decisions
    Notable choices and the reasoning behind them — only decisions that
    constrain future work. Format each as "Decision — rationale". Skip
    routine implementation details.

  Inputs are split into two groups:

    - "Durable knowledge" — semantic memories, propositions. These are
      your primary signal. Quote vocabulary, module names, and constraints
      from here.
    - "Recent events" — episodic observation/action pairs. Use ONLY to
      infer recurring patterns or stable decisions. Never narrate these
      events. If an event is one-off, ignore it.

  Respond as a JSON object with `content` (a 250-500 word markdown body
  using the sections above) and `frontmatter`. The `frontmatter` object
  has two array fields:

    - `topics`: section titles or topical areas covered, in order.
    - `key_concepts`: recurring named entities, modules, files, or
      vocabulary worth indexing.

  Use empty arrays when nothing fits.
  """

  @type input :: %{semantic: [map()], episodic: [map()]} | [map()]

  @spec summarize(input(), String.t() | nil) ::
          {:ok, %{content: String.t(), frontmatter: map()}} | {:error, term()}
  def summarize(memories, charter) do
    messages = [
      Message.system(@system),
      Message.user(build_prompt(memories, charter))
    ]

    case Sycophant.generate_object(llm_model(), messages, @schema) do
      {:ok, %{object: %{content: content, frontmatter: frontmatter}}} ->
        {:ok, %{content: content, frontmatter: frontmatter}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(memories, charter) do
    {semantic, episodic} = split(memories)

    """
    #{charter_section(charter)}Durable knowledge (semantic memories — primary signal):
    #{format_memories(semantic)}

    Recent events (episodic memories — use only to infer durable patterns):
    #{format_memories(episodic)}

    Distill these into the project summary. Return only durable knowledge.
    """
  end

  defp split(%{semantic: semantic, episodic: episodic})
       when is_list(semantic) and is_list(episodic),
       do: {semantic, episodic}

  defp split(memories) when is_list(memories) do
    Enum.split_with(memories, &semantic?/1)
  end

  defp semantic?(%{node: %{proposition: p}}) when is_binary(p), do: true
  defp semantic?(_), do: false

  defp charter_section(content) when is_binary(content) and content != "" do
    "Project charter:\n#{content}\n\n"
  end

  defp charter_section(_), do: ""

  defp format_memories([]), do: "(none)"

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
