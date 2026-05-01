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
    test "returns markdown with playbook, charter, summary and recent_memories regions",
         %{conn: conn} do
      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "Ship small."
        })

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "summary",
          content: "In alpha."
        })

      conn = get(conn, "/api/projects/p/session_primer")
      body = json_response(conn, 200)

      assert body["format"] == "markdown"
      assert body["content"] =~ "region:playbook"
      assert body["content"] =~ "region:charter"
      assert body["content"] =~ "region:summary"
      assert body["content"] =~ "region:recent_memories"
      assert body["content"] =~ "Ship small."
      assert body["content"] =~ "In alpha."
    end

    test "omits the charter region when no charter row exists", %{conn: conn} do
      conn = get(conn, "/api/projects/p/session_primer")
      body = json_response(conn, 200)

      refute body["content"] =~ "region:charter"
    end

    test "honors recent_count query parameter", %{conn: conn} do
      conn = get(conn, "/api/projects/p/session_primer?recent_count=3")
      body = json_response(conn, 200)

      assert body["format"] == "markdown"
      assert is_binary(body["content"])
    end

    test "returns 422 invalid_params when recent_count is not an integer", %{conn: conn} do
      conn = get(conn, "/api/projects/p/session_primer?recent_count=abc")
      body = json_response(conn, 422)

      assert body["error"]["code"] == "invalid_params"
    end
  end
end
