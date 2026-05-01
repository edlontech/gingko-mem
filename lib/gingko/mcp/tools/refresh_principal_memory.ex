defmodule Gingko.MCP.Tools.RefreshPrincipalMemory do
  @moduledoc """
  MCP tool that enqueues an immediate regeneration of the project summary,
  bypassing the automatic debounce.
  """

  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse
  alias Gingko.Summaries.ProjectSummaryWorker

  def name, do: "refresh_principal_memory"

  def description do
    """
    Enqueue an on-demand regeneration of the project summary, bypassing the \
    automatic debounce.
    """
  end

  schema do
    field(:project_id, :string, required: true, description: "The project identifier.")
  end

  def execute(args, frame) do
    project_id = args[:project_id] || args["project_id"]

    %{project_key: project_id}
    |> ProjectSummaryWorker.new(unique: false)
    |> Oban.insert()
    |> case do
      {:ok, job} ->
        {:ok,
         %{
           enqueued_jobs: [
             %{id: job.id, worker: "ProjectSummaryWorker", args: job.args}
           ]
         }}

      {:error, reason} ->
        {:error, %{code: :enqueue_failed, message: inspect(reason)}}
    end
    |> ToolResponse.from_result(frame)
  end
end
