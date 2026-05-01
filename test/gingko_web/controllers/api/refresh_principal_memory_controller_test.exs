defmodule GingkoWeb.Api.RefreshPrincipalMemoryControllerTest do
  use GingkoWeb.ConnCase, async: false
  use Oban.Testing, repo: Gingko.Repo

  alias Gingko.Summaries.ProjectSummaryWorker

  setup do
    on_exit(fn -> Gingko.DataCase.clean_summaries_tables() end)

    Gingko.DataCase.clean_summaries_tables()
    Gingko.Repo.query!("DELETE FROM oban_jobs")

    :ok
  end

  describe "POST /api/projects/:project_id/summaries/refresh" do
    test "enqueues a ProjectSummaryWorker job", %{conn: conn} do
      conn = post(conn, "/api/projects/p/summaries/refresh", %{})
      body = json_response(conn, 200)

      assert [%{"worker" => "ProjectSummaryWorker"}] = body["enqueued_jobs"]
      assert [_] = all_enqueued(worker: ProjectSummaryWorker, args: %{project_key: "p"})
    end

    test "bypasses debounce when a matching job is already scheduled", %{conn: conn} do
      {:ok, _pre} =
        %{project_key: "p"} |> ProjectSummaryWorker.new() |> Oban.insert()

      conn = post(conn, "/api/projects/p/summaries/refresh", %{})
      _body = json_response(conn, 200)

      jobs = all_enqueued(worker: ProjectSummaryWorker, args: %{project_key: "p"})
      assert length(jobs) == 2
    end
  end
end
