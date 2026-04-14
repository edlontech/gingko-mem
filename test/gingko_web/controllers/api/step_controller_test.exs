defmodule GingkoWeb.Api.StepControllerTest do
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

    project_id = "api-step-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _} = Gingko.Memory.open_project(project_id)

    {:ok, %{session_id: session_id}} =
      Gingko.Memory.start_session(%{project_id: project_id, goal: "test"})

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
    end)

    %{session_id: session_id}
  end

  describe "POST /api/sessions/:session_id/steps" do
    test "appends a step and returns 202", %{conn: conn, session_id: session_id} do
      conn =
        post(conn, "/api/sessions/#{session_id}/steps", %{
          "observation" => "saw something",
          "action" => "did something"
        })

      body = json_response(conn, 202)
      assert body["session_id"] == session_id
    end

    test "returns 422 when observation is missing", %{conn: conn, session_id: session_id} do
      conn = post conn, "/api/sessions/#{session_id}/steps", %{"action" => "did something"}
      assert json_response(conn, 422)["error"]["code"] == "invalid_params"
    end

    test "returns 422 when action is missing", %{conn: conn, session_id: session_id} do
      conn = post conn, "/api/sessions/#{session_id}/steps", %{"observation" => "saw something"}
      assert json_response(conn, 422)["error"]["code"] == "invalid_params"
    end
  end
end
