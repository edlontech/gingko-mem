defmodule Gingko.Summaries.PrincipalStateWorker do
  @moduledoc """
  Oban worker that regenerates the project-level `state` section from the
  current cluster summaries. Debounced via Oban's `unique` clause to coalesce
  bursty enqueues from `Gingko.Summaries.ClusterWorker`.

  A locked `:state` row is never overwritten — the job discards with
  `{:discard, "state locked"}`.
  """

  use Oban.Worker,
    queue: :summaries,
    unique: [
      fields: [:args],
      keys: [:project_key],
      states: [:available, :scheduled],
      period: 60
    ]

  alias Gingko.Summaries
  alias Gingko.Summaries.Config
  alias Gingko.Summaries.PrincipalStateSummarizer
  alias Gingko.Summaries.WorkerSupport

  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{project_key: project_key} = args) when is_binary(project_key) do
    period = Config.principal_regen_debounce_seconds()

    args
    |> new(schedule_in: period, unique: [period: period])
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_key" => project_key}}) do
    WorkerSupport.if_enabled(fn -> run(project_key) end)
  end

  defp run(project_key) do
    case Summaries.get_section(project_key, "state") do
      %{locked: true} ->
        {:discard, "state locked"}

      _ ->
        generate(project_key)
    end
  end

  defp generate(project_key) do
    clusters =
      project_key
      |> Summaries.list_clusters()
      |> Enum.reject(& &1.locked)

    charter = charter_for(project_key)

    {summary_result, duration_ms} =
      WorkerSupport.with_duration(fn ->
        PrincipalStateSummarizer.summarize(clusters, charter)
      end)

    case summary_result do
      {:ok, %{content: content, frontmatter: frontmatter}} ->
        {:ok, _} = Summaries.finalize_state_regen(project_key, content, frontmatter, clusters)

        WorkerSupport.emit(
          [:gingko, :summaries, :principal, :regenerated],
          duration_ms,
          %{project_key: project_key, source_cluster_count: length(clusters), ok: true}
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp charter_for(project_key) do
    case Summaries.get_section(project_key, "charter") do
      %{content: content} = section when is_binary(content) and content != "" -> section
      _ -> nil
    end
  end
end
