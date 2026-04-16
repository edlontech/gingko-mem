defmodule Gingko.Summaries.ClusterWorker do
  @moduledoc """
  Oban worker that regenerates a single cluster summary. Triggered by
  `Gingko.Summaries.DirtyTracker` whenever a tag's membership set changes.

  Runs in `:incremental` mode most of the time (previous summary + new memories)
  and `:full` mode every 50th regen or while the cluster has fewer than 30
  memories, to prevent drift. On success it enqueues
  `Gingko.Summaries.PrincipalStateWorker` to roll the cluster headline up into
  the project-level state document.
  """

  use Oban.Worker,
    queue: :summaries,
    unique: [
      fields: [:args],
      keys: [:project_key, :tag_node_id],
      states: [:available, :scheduled],
      period: :infinity
    ]

  alias Gingko.Memory
  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterSummarizer
  alias Gingko.Summaries.ClusterSummary
  alias Gingko.Summaries.PrincipalStateWorker
  alias Gingko.Summaries.WorkerSupport

  @spec enqueue(map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%{project_key: project_key, tag_node_id: tag_node_id} = args)
      when is_binary(project_key) and is_binary(tag_node_id) do
    args |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_key" => project_key, "tag_node_id" => tag_node_id}}) do
    WorkerSupport.if_enabled(fn ->
      case Summaries.get_cluster(project_key, tag_node_id) do
        nil -> {:discard, "cluster not found"}
        cluster -> run(cluster, project_key, tag_node_id)
      end
    end)
  end

  defp run(cluster, project_key, tag_node_id) do
    mode = choose_mode(cluster)

    with {:ok, memories} <- fetch_memories(project_key, tag_node_id, cluster, mode) do
      {summary_result, duration_ms} =
        WorkerSupport.with_duration(fn ->
          ClusterSummarizer.summarize(cluster, memories, mode)
        end)

      case summary_result do
        {:ok, result} ->
          finalize(cluster, project_key, tag_node_id, result, mode, duration_ms)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp finalize(cluster, project_key, tag_node_id, result, mode, duration_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} = Summaries.finalize_cluster_regen(cluster, result, mode, duration_ms, now)
    Summaries.delete_deltas_up_to(project_key, tag_node_id, now)

    PrincipalStateWorker.enqueue(%{project_key: project_key})

    WorkerSupport.emit(
      [:gingko, :summaries, :cluster, :regenerated],
      duration_ms,
      %{
        project_key: project_key,
        tag_node_id: tag_node_id,
        regen_count: cluster.regen_count + 1,
        mode: mode,
        ok: true
      }
    )

    :ok
  end

  defp choose_mode(%ClusterSummary{regen_count: regen_count, memory_count: memory_count}) do
    if rem(regen_count, 50) == 0 or memory_count < 30 do
      :full
    else
      :incremental
    end
  end

  defp fetch_memories(project_key, tag_node_id, cluster, :incremental) do
    deltas = Summaries.deltas_since(project_key, tag_node_id, cluster.last_generated_at)
    ids = deltas |> Enum.map(& &1.memory_node_id) |> Enum.uniq()
    Memory.get_nodes(project_key, ids)
  end

  defp fetch_memories(project_key, tag_node_id, _cluster, :full) do
    Memory.memories_linked_to_tag(project_key, tag_node_id)
  end
end
