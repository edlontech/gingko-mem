defmodule Gingko.Summaries.ProjectSummaryWorker do
  @moduledoc """
  Oban worker that regenerates the project-level `summary` section from the
  most recent memories plus the optional charter. Triggered by
  `Gingko.Summaries.DirtyTracker` whenever a memory is appended; coalesced via
  Oban's `unique` clause so bursty appends produce a single regen.

  A locked `:summary` row is never overwritten — the job discards with
  `{:discard, "summary locked"}`.
  """

  use Oban.Worker,
    queue: :summaries,
    unique: [
      fields: [:args],
      keys: [:project_key],
      states: [:available, :scheduled],
      period: :infinity
    ]

  alias Gingko.Memory
  alias Gingko.Summaries
  alias Gingko.Summaries.Config
  alias Gingko.Summaries.ProjectSummarizer
  alias Gingko.Summaries.WorkerSupport

  # Bias toward durable propositions over chronological events when building
  # the project "constitution".
  @semantic_ratio 0.75

  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{project_key: project_key} = args) when is_binary(project_key) do
    period = Config.regen_debounce_seconds()

    args
    |> new(schedule_in: period, unique: [period: period])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_key" => project_key}}) do
    WorkerSupport.if_enabled(fn -> run(project_key) end)
  end

  defp run(project_key) do
    case Summaries.get_section(project_key, "summary") do
      %{locked: true} ->
        {:discard, "summary locked"}

      _ ->
        generate(project_key)
    end
  end

  defp generate(project_key) do
    charter = charter_for(project_key)
    %{semantic: semantic, episodic: episodic} = inputs = fetch_inputs(project_key)

    {summary_result, duration_ms} =
      WorkerSupport.with_duration(fn ->
        ProjectSummarizer.summarize(inputs, charter)
      end)

    case summary_result do
      {:ok, %{content: content, frontmatter: frontmatter}} ->
        {:ok, _} =
          Summaries.upsert_section(%{
            project_key: project_key,
            kind: "summary",
            content: content,
            frontmatter: frontmatter
          })

        WorkerSupport.emit(
          [:gingko, :summaries, :project, :regenerated],
          duration_ms,
          %{
            project_key: project_key,
            memory_count: length(semantic) + length(episodic),
            semantic_count: length(semantic),
            episodic_count: length(episodic),
            ok: true
          }
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp charter_for(project_key) do
    case Summaries.get_section(project_key, "charter") do
      %{content: content} when is_binary(content) and content != "" -> content
      _ -> nil
    end
  end

  defp fetch_inputs(project_key) do
    total = Config.summary_memory_count()
    semantic_k = max(1, round(total * @semantic_ratio))
    episodic_k = max(1, total - semantic_k)

    %{
      semantic: fetch_by_type(project_key, :semantic, semantic_k),
      episodic: fetch_by_type(project_key, :episodic, episodic_k)
    }
  end

  defp fetch_by_type(project_key, type, top_k) do
    case Memory.latest_memories(%{
           project_id: project_key,
           top_k: top_k,
           types: [type]
         }) do
      {:ok, %{memories: memories}} -> memories
      {:error, _} -> []
    end
  end
end
