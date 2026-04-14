defmodule GingkoWeb.Api.SessionControllerTest do
  use GingkoWeb.ConnCase, async: false
  use Mimic

  setup :set_mimic_global

  setup do
    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, fn _msgs, _opts ->
      {:ok, %Mnemosyne.LLM.Response{content: "mock response", model: "mock:test", usage: %{}}}
    end)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, fn _msgs, _schema, _opts ->
      {:ok, %Mnemosyne.LLM.Response{content: %{}, model: "mock:test", usage: %{}}}
    end)

    project_id = "api-session-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _} = Gingko.Memory.open_project(project_id)

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
    end)

    %{project_id: project_id}
  end

  describe "POST /api/projects/:project_id/sessions" do
    test "creates a session", %{conn: conn, project_id: project_id} do
      conn =
        post(conn, "/api/projects/#{project_id}/sessions", %{
          "goal" => "test goal",
          "agent" => "test-agent"
        })

      body = json_response(conn, 201)
      assert body["project_id"] == project_id
      assert body["state"] == "collecting"
      assert is_binary(body["session_id"])
    end

    test "returns 422 when goal is missing", %{conn: conn, project_id: project_id} do
      conn = post conn, "/api/projects/#{project_id}/sessions", %{}
      assert json_response(conn, 422)["error"]["code"] == "invalid_params"
    end
  end

  describe "GET /api/sessions/:session_id/state" do
    test "returns session state", %{conn: conn, project_id: project_id} do
      {:ok, %{session_id: session_id}} =
        Gingko.Memory.start_session(%{project_id: project_id, goal: "test"})

      conn = get(conn, "/api/sessions/#{session_id}/state")
      body = json_response(conn, 200)
      assert body["session_id"] == session_id
      assert is_binary(body["state"])
    end

    test "returns 404 for unknown session", %{conn: conn} do
      conn = get(conn, "/api/sessions/nonexistent-session/state")
      assert json_response(conn, 404)["error"]["code"] == "session_not_found"
    end
  end

  describe "POST /api/sessions/:session_id/commit" do
    test "commits a session", %{conn: conn, project_id: project_id} do
      {:ok, %{session_id: session_id}} =
        Gingko.Memory.start_session(%{project_id: project_id, goal: "test"})

      conn = post(conn, "/api/sessions/#{session_id}/commit")
      body = json_response(conn, 200)
      assert body["session_id"] == session_id
      assert body["state"] == "closing"
    end
  end
end
