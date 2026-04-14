defmodule GingkoWeb.Api.SessionPrimerControllerTest do
  use GingkoWeb.ConnCase, async: false

  alias Gingko.Summaries

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config,
      enabled: true,
      session_primer_recent_count: 5
    )

    on_exit(fn ->
      Application.delete_env(:gingko, Gingko.Summaries.Config)
      Gingko.DataCase.clean_summaries_tables()
    end)

    Gingko.DataCase.clean_summaries_tables()
    :ok
  end

  describe "GET /api/projects/:project_id/session_primer" do
    test "returns a markdown-formatted primer with all five regions when populated",
         %{conn: conn} do
      {:ok, _} = Summaries.seed_playbook("p")

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "Ship small."
        })

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "state",
          content: "In alpha."
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 5,
          headline: "auth summary",
          dirty: false
        })

      conn = get(conn, "/api/projects/p/session_primer")
      body = json_response(conn, 200)

      assert body["format"] == "markdown"
      assert body["content"] =~ "region:playbook"
      assert body["content"] =~ "region:charter"
      assert body["content"] =~ "region:state"
      assert body["content"] =~ "region:cluster_index"
      assert body["content"] =~ "region:recent_memories"
      assert body["content"] =~ "**auth**"
    end

    test "omits the charter region when no charter row exists", %{conn: conn} do
      {:ok, _} = Summaries.seed_playbook("p")

      conn = get(conn, "/api/projects/p/session_primer")
      body = json_response(conn, 200)

      refute body["content"] =~ "region:charter"
    end

    test "honors recent_count query parameter", %{conn: conn} do
      {:ok, _} = Summaries.seed_playbook("p")

      conn = get(conn, "/api/projects/p/session_primer?recent_count=3")
      body = json_response(conn, 200)

      assert body["format"] == "markdown"
      assert is_binary(body["content"])
    end

    test "returns 422 invalid_params when recent_count is not an integer", %{conn: conn} do
      {:ok, _} = Summaries.seed_playbook("p")

      conn = get(conn, "/api/projects/p/session_primer?recent_count=abc")
      body = json_response(conn, 422)

      assert body["error"]["code"] == "invalid_params"
    end
  end
end
