defmodule Gingko.MCP.Tools.RefreshPrincipalMemoryTest do
  use Gingko.DataCase, async: false
  use Oban.Testing, repo: Gingko.Repo

  alias Anubis.Server.Frame
  alias Gingko.MCP.Tools.RefreshPrincipalMemory
  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.PrincipalStateWorker

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)
    on_exit(fn -> Application.delete_env(:gingko, Gingko.Summaries.Config) end)

    Gingko.Repo.query!("DELETE FROM oban_jobs")

    :ok
  end

  describe "execute/2 scope=state" do
    test "enqueues a PrincipalStateWorker job for the project" do
      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "state"},
          Frame.new()
        )

      refute Map.get(response, :isError)
      assert [_] = all_enqueued(worker: PrincipalStateWorker, args: %{project_key: "p"})
      assert [] = all_enqueued(worker: ClusterWorker)

      assert [%{"worker" => "PrincipalStateWorker"}] =
               response.structured_content["enqueued_jobs"]
    end
  end

  describe "execute/2 scope=cluster" do
    setup do
      {:ok, cluster} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "tag-1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 5,
          dirty: false
        })

      %{cluster: cluster}
    end

    test "enqueues a ClusterWorker job when given cluster_slug", %{cluster: cluster} do
      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "cluster", "cluster_slug" => "auth"},
          Frame.new()
        )

      refute Map.get(response, :isError)

      assert [_] =
               all_enqueued(
                 worker: ClusterWorker,
                 args: %{project_key: "p", tag_node_id: cluster.tag_node_id}
               )

      assert [] = all_enqueued(worker: PrincipalStateWorker)
    end

    test "returns cluster_not_found when the slug is unknown" do
      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "cluster", "cluster_slug" => "nope"},
          Frame.new()
        )

      assert response.isError == true
      assert %{"error" => %{"code" => "cluster_not_found"}} = response.structured_content
      assert [] = all_enqueued(worker: ClusterWorker)
    end

    test "returns invalid_params when cluster_slug is missing" do
      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "cluster"},
          Frame.new()
        )

      assert response.isError == true
      assert %{"error" => %{"code" => "invalid_params"}} = response.structured_content
    end
  end

  describe "execute/2 scope=all" do
    test "enqueues one PrincipalStateWorker and one ClusterWorker per cluster in the project" do
      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10,
          dirty: false
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Graph",
          slug: "graph",
          memory_count: 7,
          dirty: false
        })

      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "all"},
          Frame.new()
        )

      refute Map.get(response, :isError)
      assert [_] = all_enqueued(worker: PrincipalStateWorker, args: %{project_key: "p"})

      cluster_jobs = all_enqueued(worker: ClusterWorker, args: %{project_key: "p"})
      assert length(cluster_jobs) == 2

      tag_ids = Enum.map(cluster_jobs, & &1.args["tag_node_id"])
      assert "t1" in tag_ids
      assert "t2" in tag_ids

      enqueued = response.structured_content["enqueued_jobs"]
      assert length(enqueued) == 3
    end

    test "defaults scope to all when scope is omitted" do
      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10
        })

      {:reply, _response, _frame} =
        RefreshPrincipalMemory.execute(%{"project_id" => "p"}, Frame.new())

      assert [_] = all_enqueued(worker: PrincipalStateWorker)
      assert [_] = all_enqueued(worker: ClusterWorker)
    end
  end

  describe "execute/2 invalid scope" do
    test "returns invalid_params" do
      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "bogus"},
          Frame.new()
        )

      assert response.isError == true
      assert %{"error" => %{"code" => "invalid_params"}} = response.structured_content
    end
  end

  describe "execute/2 bypasses debounce" do
    test "enqueues a new state job even when a scheduled state job already exists" do
      {:ok, _pre} =
        %{project_key: "p"} |> PrincipalStateWorker.new() |> Oban.insert()

      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "state"},
          Frame.new()
        )

      refute Map.get(response, :isError)

      jobs = all_enqueued(worker: PrincipalStateWorker, args: %{project_key: "p"})
      assert length(jobs) == 2
    end

    test "enqueues a new cluster job even when a scheduled cluster job already exists" do
      {:ok, _cluster} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "tag-1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 5
        })

      {:ok, _pre} =
        %{project_key: "p", tag_node_id: "tag-1"}
        |> ClusterWorker.new()
        |> Oban.insert()

      {:reply, response, _frame} =
        RefreshPrincipalMemory.execute(
          %{"project_id" => "p", "scope" => "cluster", "cluster_slug" => "auth"},
          Frame.new()
        )

      refute Map.get(response, :isError)

      jobs =
        all_enqueued(
          worker: ClusterWorker,
          args: %{project_key: "p", tag_node_id: "tag-1"}
        )

      assert length(jobs) == 2
    end
  end
end
