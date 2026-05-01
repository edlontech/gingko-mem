defmodule Gingko.Summaries.ProjectSummarizer do
  @moduledoc """
  LLM-backed summarizer that produces a single project-level "constitution"
  from the most recent memories plus an optional charter. Called by
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
  You maintain the project summary — a living "constitution" describing what
  the user is working on, recurring themes, and notable decisions across the
  most recent memories. The summary is read at the start of every session as
  durable context for the agent.

  Lead with a concise statement of the project's current focus. Follow with
  recurring themes (architecture, conventions, vocabulary, constraints) and
  notable decisions and their reasoning. Write declaratively, in the present
  tense, as stored knowledge. Do not produce status reports, roadmaps, or
  "next steps" sections.

  Respond as a JSON object with `content` (a 300-600 word markdown body) and
  `frontmatter`. The `frontmatter` object has two array fields:

    - `topics`: section titles or topical areas covered, in order.
    - `key_concepts`: recurring named entities, modules, files, or vocabulary
      worth indexing.

  Use empty arrays when nothing fits.
  """

  @spec summarize([map()], String.t() | nil) ::
          {:ok, %{content: String.t(), frontmatter: map()}} | {:error, term()}
  def summarize(memories, charter) when is_list(memories) do
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
    charter_section =
      case charter do
        content when is_binary(content) and content != "" ->
          "Project charter:\n#{content}\n\n"

        _ ->
          ""
      end

    """
    #{charter_section}Recent memories (newest first):
    #{format_memories(memories)}

    Distill these into the project summary.
    """
  end

  defp format_memories([]), do: "(no memories yet)"

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
