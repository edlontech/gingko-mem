defmodule Gingko.MCP.Tools.RefreshPrincipalMemoryTest do
  use Gingko.DataCase, async: false
  use Oban.Testing, repo: Gingko.Repo

  alias Anubis.Server.Frame
  alias Gingko.MCP.Tools.RefreshPrincipalMemory
  alias Gingko.Summaries.ProjectSummaryWorker

  setup do
    Gingko.Repo.query!("DELETE FROM oban_jobs")
    :ok
  end

  describe "execute/2" do
    test "enqueues a ProjectSummaryWorker job for the project" do
      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(%{"project_id" => "p"}, Frame.new())

      refute Map.get(response, :isError)
      assert [_] = all_enqueued(worker: ProjectSummaryWorker, args: %{project_key: "p"})

      assert [%{"worker" => "ProjectSummaryWorker"}] =
               response.structured_content["enqueued_jobs"]
    end

    test "bypasses debounce when a matching job is already scheduled" do
      {:ok, _pre} =
        %{project_key: "p"} |> ProjectSummaryWorker.new() |> Oban.insert()

      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(%{"project_id" => "p"}, Frame.new())

      refute Map.get(response, :isError)

      jobs = all_enqueued(worker: ProjectSummaryWorker, args: %{project_key: "p"})
      assert length(jobs) == 2
    end
  end
end
