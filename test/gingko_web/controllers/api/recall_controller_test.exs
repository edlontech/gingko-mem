defmodule GingkoWeb.Api.RecallControllerTest do
  use GingkoWeb.ConnCase, async: false
  use Mimic

  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult

  setup :set_mimic_global

  setup do
    Mimic.copy(Mnemosyne)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, fn _msgs, _opts ->
      {:ok, %Mnemosyne.LLM.Response{content: "mock response", model: "mock:test", usage: %{}}}
    end)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, fn _msgs, _schema, _opts ->
      {:ok, %Mnemosyne.LLM.Response{content: %{}, model: "mock:test", usage: %{}}}
    end)

    project_id = "api-recall-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _} = Gingko.Memory.open_project(project_id)

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
    end)

    %{project_id: project_id}
  end

  describe "GET /api/projects/:project_id/recall" do
    test "returns recall results", %{conn: conn, project_id: project_id} do
      stub(Mnemosyne, :recall, fn _repo_id, _query ->
        {:ok,
         %RecallResult{reasoned: %ReasonedMemory{semantic: "test summary"}, touched_nodes: []}}
      end)

      conn = get conn, "/api/projects/#{project_id}/recall", %{"query" => "test query"}
      body = json_response(conn, 200)
      assert body["project_id"] == project_id
      assert body["query"] == "test query"
      assert is_map(body["memory"])
    end

    test "returns 422 when query is missing", %{conn: conn, project_id: project_id} do
      conn = get(conn, "/api/projects/#{project_id}/recall")
      assert json_response(conn, 422)["error"]["code"] == "invalid_params"
    end
  end
end
