defmodule GingkoWeb.Api.SummariesStatusControllerTest do
  use GingkoWeb.ConnCase, async: false

  describe "GET /api/summaries/status" do
    test "returns 200 with enabled=true when summaries are enabled", %{conn: conn} do
      Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)
      on_exit(fn -> Application.delete_env(:gingko, Gingko.Summaries.Config) end)

      conn = get(conn, "/api/summaries/status")
      assert %{"enabled" => true} = json_response(conn, 200)
    end

    test "returns 503 with enabled=false when summaries are disabled", %{conn: conn} do
      Application.put_env(:gingko, Gingko.Summaries.Config, enabled: false)
      on_exit(fn -> Application.delete_env(:gingko, Gingko.Summaries.Config) end)

      conn = get(conn, "/api/summaries/status")
      assert %{"enabled" => false} = json_response(conn, 503)
    end
  end
end
