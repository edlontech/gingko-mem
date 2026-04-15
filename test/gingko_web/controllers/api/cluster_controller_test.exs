defmodule GingkoWeb.Api.ClusterControllerTest do
  use GingkoWeb.ConnCase, async: false

  alias Gingko.Summaries

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)

    on_exit(fn ->
      Application.delete_env(:gingko, Gingko.Summaries.Config)
      Gingko.DataCase.clean_summaries_tables()
    end)

    Gingko.DataCase.clean_summaries_tables()

    {:ok, cluster} =
      Summaries.upsert_cluster(%{
        project_key: "p",
        tag_node_id: "tag-1",
        tag_label: "Auth",
        slug: "auth",
        memory_count: 9,
        headline: "auth summary",
        content: "auth body",
        dirty: false
      })

    %{cluster: cluster}
  end

  describe "GET /api/projects/:project_id/clusters/:slug" do
    test "returns the cluster record", %{conn: conn, cluster: cluster} do
      conn = get(conn, "/api/projects/p/clusters/auth")
      body = json_response(conn, 200)

      assert body["slug"] == "auth"
      assert body["tag_node_id"] == cluster.tag_node_id
      assert body["headline"] == "auth summary"
      assert body["content"] == "auth body"
      assert body["memory_count"] == 9
    end

    test "returns a 404 cluster_not_found for unknown slug", %{conn: conn} do
      conn = get(conn, "/api/projects/p/clusters/missing")
      body = json_response(conn, 404)

      assert body["error"]["code"] == "cluster_not_found"
      assert body["error"]["message"] =~ "missing"
    end
  end
end
