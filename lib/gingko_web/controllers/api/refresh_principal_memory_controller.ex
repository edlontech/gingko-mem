defmodule GingkoWeb.Api.RefreshPrincipalMemoryController do
  @moduledoc false

  use GingkoWeb, :controller

  alias Gingko.Summaries.ProjectSummaryWorker

  action_fallback GingkoWeb.Api.FallbackController

  def create(conn, %{"project_id" => project_id}) do
    %{project_key: project_id}
    |> ProjectSummaryWorker.new(unique: false)
    |> Oban.insert()
    |> case do
      {:ok, job} ->
        json(conn, %{
          enqueued_jobs: [
            %{id: job.id, worker: "ProjectSummaryWorker", args: job.args}
          ]
        })

      {:error, reason} ->
        {:error, %{code: :enqueue_failed, message: inspect(reason)}}
    end
  end
end
