defmodule Gingko.Summaries.Refresh do
  @moduledoc """
  Shared logic for enqueueing principal-memory refreshes. Used by both the
  `refresh_principal_memory` MCP tool and the matching REST controller.
  """

  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterSummary
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.PrincipalStateWorker

  @valid_scopes ~w(all state cluster)

  @type job_descriptor :: %{id: integer(), worker: String.t(), args: map()}

  @spec run(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, %{enqueued_jobs: [job_descriptor()]}} | {:error, map()}
  def run(project_id, scope \\ "all", cluster_slug \\ nil)

  def run(_project_id, scope, _cluster_slug)
      when is_binary(scope) and scope not in @valid_scopes do
    {:error,
     %{
       code: :invalid_params,
       message: "scope must be one of: #{Enum.join(@valid_scopes, ", ")}"
     }}
  end

  def run(project_id, "state", _cluster_slug) do
    with {:ok, job} <- enqueue_state(project_id) do
      {:ok, %{enqueued_jobs: [describe_job(job)]}}
    end
  end

  def run(_project_id, "cluster", nil) do
    {:error,
     %{
       code: :invalid_params,
       message: "`cluster_slug` is required when scope is `cluster`"
     }}
  end

  def run(project_id, "cluster", cluster_slug) do
    case Summaries.get_cluster_by_slug(project_id, cluster_slug) do
      %ClusterSummary{tag_node_id: tag_node_id} ->
        with {:ok, job} <- enqueue_cluster(project_id, tag_node_id) do
          {:ok, %{enqueued_jobs: [describe_job(job)]}}
        end

      nil ->
        {:error,
         %{
           code: :cluster_not_found,
           message: "cluster not found for slug=#{cluster_slug}"
         }}
    end
  end

  def run(project_id, "all", _cluster_slug) do
    with {:ok, state_job} <- enqueue_state(project_id),
         {:ok, cluster_jobs} <- enqueue_all_clusters(project_id) do
      {:ok, %{enqueued_jobs: [describe_job(state_job) | cluster_jobs]}}
    end
  end

  def run(project_id, nil, cluster_slug), do: run(project_id, "all", cluster_slug)

  defp enqueue_all_clusters(project_id) do
    project_id
    |> Summaries.list_clusters()
    |> Enum.reduce_while([], fn cluster, acc ->
      case enqueue_cluster(project_id, cluster.tag_node_id) do
        {:ok, job} -> {:cont, [describe_job(job) | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      jobs when is_list(jobs) -> {:ok, Enum.reverse(jobs)}
    end
  end

  defp enqueue_state(project_id) do
    %{project_key: project_id}
    |> PrincipalStateWorker.new(unique: false)
    |> Oban.insert()
  end

  defp enqueue_cluster(project_id, tag_node_id) do
    %{project_key: project_id, tag_node_id: tag_node_id}
    |> ClusterWorker.new(unique: false)
    |> Oban.insert()
  end

  defp describe_job(%Oban.Job{} = job) do
    %{
      id: job.id,
      worker: short_worker_name(job.worker),
      args: job.args
    }
  end

  defp short_worker_name(worker) when is_binary(worker) do
    worker |> String.split(".") |> List.last()
  end
end
