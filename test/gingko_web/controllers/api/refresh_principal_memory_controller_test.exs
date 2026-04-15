defmodule GingkoWeb.Api.RefreshPrincipalMemoryControllerTest do
  use GingkoWeb.ConnCase, async: false
  use Oban.Testing, repo: Gingko.Repo

  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.PrincipalStateWorker

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)

    on_exit(fn ->
      Application.delete_env(:gingko, Gingko.Summaries.Config)
      Gingko.DataCase.clean_summaries_tables()
    end)

    Gingko.DataCase.clean_summaries_tables()
    Gingko.Repo.query!("DELETE FROM oban_jobs")

    :ok
  end

  describe "POST /api/projects/:project_id/summaries/refresh" do
    test "enqueues a PrincipalStateWorker job with scope=state", %{conn: conn} do
      conn = post(conn, "/api/projects/p/summaries/refresh", %{"scope" => "state"})
      body = json_response(conn, 200)

      assert [%{"worker" => "PrincipalStateWorker"}] = body["enqueued_jobs"]
      assert [_] = all_enqueued(worker: PrincipalStateWorker, args: %{project_key: "p"})
      assert [] = all_enqueued(worker: ClusterWorker)
    end

    test "enqueues a ClusterWorker job with scope=cluster and cluster_slug", %{conn: conn} do
      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "tag-1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 5
        })

      conn =
        post(conn, "/api/projects/p/summaries/refresh", %{
          "scope" => "cluster",
          "cluster_slug" => "auth"
        })

      body = json_response(conn, 200)

      assert [%{"worker" => "ClusterWorker"}] = body["enqueued_jobs"]

      assert [_] =
               all_enqueued(
                 worker: ClusterWorker,
                 args: %{project_key: "p", tag_node_id: "tag-1"}
               )
    end

    test "enqueues one state job plus one cluster job per cluster with scope=all",
         %{conn: conn} do
      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Graph",
          slug: "graph",
          memory_count: 4
        })

      conn = post(conn, "/api/projects/p/summaries/refresh", %{"scope" => "all"})
      body = json_response(conn, 200)

      assert length(body["enqueued_jobs"]) == 3
      assert [_] = all_enqueued(worker: PrincipalStateWorker, args: %{project_key: "p"})
      assert 2 == length(all_enqueued(worker: ClusterWorker, args: %{project_key: "p"}))
    end

    test "returns 404 cluster_not_found when cluster_slug is unknown", %{conn: conn} do
      conn =
        post(conn, "/api/projects/p/summaries/refresh", %{
          "scope" => "cluster",
          "cluster_slug" => "no-such-cluster"
        })

      body = json_response(conn, 404)
      assert body["error"]["code"] == "cluster_not_found"
      assert [] = all_enqueued(worker: ClusterWorker)
    end

    test "returns 422 invalid_params for invalid scope", %{conn: conn} do
      conn = post(conn, "/api/projects/p/summaries/refresh", %{"scope" => "bogus"})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "invalid_params"
    end

    test "bypasses debounce when a matching state job is already scheduled", %{conn: conn} do
      {:ok, _pre} =
        %{project_key: "p"} |> PrincipalStateWorker.new() |> Oban.insert()

      conn = post(conn, "/api/projects/p/summaries/refresh", %{"scope" => "state"})
      _body = json_response(conn, 200)

      jobs = all_enqueued(worker: PrincipalStateWorker, args: %{project_key: "p"})
      assert length(jobs) == 2
    end
  end
end
