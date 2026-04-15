defmodule GingkoWeb.Api.CharterControllerTest do
  use GingkoWeb.ConnCase, async: false

  alias Gingko.Summaries

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)

    on_exit(fn ->
      Application.delete_env(:gingko, Gingko.Summaries.Config)
      Gingko.DataCase.clean_summaries_tables()
    end)

    Gingko.DataCase.clean_summaries_tables()
    :ok
  end

  describe "PUT /api/projects/:project_id/charter" do
    test "inserts a new charter row", %{conn: conn} do
      conn = put(conn, "/api/projects/p/charter", %{"content" => "Be excellent."})
      body = json_response(conn, 200)

      assert body["content"] == "Be excellent."
      assert body["kind"] == "charter"
      assert %{content: "Be excellent."} = Summaries.get_section("p", "charter")
    end

    test "replaces an existing charter", %{conn: conn} do
      {:ok, _} =
        Summaries.upsert_section(%{project_key: "p", kind: "charter", content: "old"})

      conn = put(conn, "/api/projects/p/charter", %{"content" => "new"})
      body = json_response(conn, 200)

      assert body["content"] == "new"
      assert Summaries.get_section("p", "charter").content == "new"
    end

    test "returns 409 charter_locked when the charter is locked", %{conn: conn} do
      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "pinned",
          locked: true
        })

      conn = put(conn, "/api/projects/p/charter", %{"content" => "overwrite?"})
      body = json_response(conn, 409)

      assert body["error"]["code"] == "charter_locked"
      assert Summaries.get_section("p", "charter").content == "pinned"
    end

    test "returns 422 invalid_params when content is empty", %{conn: conn} do
      conn = put(conn, "/api/projects/p/charter", %{"content" => ""})
      body = json_response(conn, 422)

      assert body["error"]["code"] == "invalid_params"
    end
  end
end
