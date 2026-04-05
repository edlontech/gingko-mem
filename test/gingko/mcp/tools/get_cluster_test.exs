defmodule Gingko.MCP.Tools.GetClusterTest do
  use Gingko.DataCase, async: false

  alias Anubis.Server.Frame
  alias Gingko.MCP.Tools.GetCluster
  alias Gingko.Summaries

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)
    on_exit(fn -> Application.delete_env(:gingko, Gingko.Summaries.Config) end)

    {:ok, cluster} =
      Summaries.upsert_cluster(%{
        project_key: "p",
        tag_node_id: "tag-1",
        tag_label: "Auth",
        slug: "auth",
        headline: "auth things",
        content: "body about auth",
        memory_count: 7,
        dirty: false
      })

    %{cluster: cluster}
  end

  describe "execute/2" do
    test "resolves a cluster by slug", %{cluster: cluster} do
      {:reply, response, _frame} =
        GetCluster.execute(%{"project_id" => "p", "slug" => "auth"}, Frame.new())

      assert response.structured_content["tag_node_id"] == cluster.tag_node_id
      assert response.structured_content["slug"] == "auth"
      assert response.structured_content["headline"] == "auth things"
      assert response.structured_content["content"] == "body about auth"
      refute Map.get(response, :isError)
    end

    test "resolves a cluster by tag_node_id" do
      {:reply, response, _frame} =
        GetCluster.execute(%{"project_id" => "p", "tag_node_id" => "tag-1"}, Frame.new())

      assert response.structured_content["slug"] == "auth"
      refute Map.get(response, :isError)
    end

    test "returns a normalized error when the slug is unknown" do
      {:reply, response, _frame} =
        GetCluster.execute(%{"project_id" => "p", "slug" => "missing"}, Frame.new())

      assert response.isError == true
      assert %{"error" => %{"code" => "cluster_not_found"} = err} = response.structured_content
      assert err["message"] =~ "missing"
    end

    test "returns a normalized error when the tag_node_id is unknown" do
      {:reply, response, _frame} =
        GetCluster.execute(
          %{"project_id" => "p", "tag_node_id" => "no-such-tag"},
          Frame.new()
        )

      assert response.isError == true
      assert %{"error" => %{"code" => "cluster_not_found"}} = response.structured_content
    end

    test "returns an invalid_params error when neither identifier is provided" do
      {:reply, response, _frame} =
        GetCluster.execute(%{"project_id" => "p"}, Frame.new())

      assert response.isError == true
      assert %{"error" => %{"code" => "invalid_params"}} = response.structured_content
    end
  end
end
