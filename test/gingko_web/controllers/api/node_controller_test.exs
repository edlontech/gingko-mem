defmodule GingkoWeb.Api.NodeControllerTest do
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

    project_id = "api-node-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _} = Gingko.Memory.open_project(project_id)

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
    end)

    %{project_id: project_id}
  end

  describe "GET /api/projects/:project_id/nodes/:node_id" do
    test "returns 404 for nonexistent node", %{conn: conn, project_id: project_id} do
      conn = get(conn, "/api/projects/#{project_id}/nodes/nonexistent-node")
      assert json_response(conn, 404)["error"]["code"] == "node_not_found"
    end

    test "returns 404 for project not open", %{conn: conn} do
      conn = get(conn, "/api/projects/not-open-project/nodes/some-node")
      assert json_response(conn, 404)["error"]["code"] == "project_not_open"
    end
  end
end
