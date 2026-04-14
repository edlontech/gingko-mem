defmodule GingkoWeb.Api.LatestMemoriesControllerTest do
  use GingkoWeb.ConnCase, async: false
  use Mimic

  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.NodeMetadata

  setup :set_mimic_global

  setup do
    Mimic.copy(Mnemosyne)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, fn _msgs, _opts ->
      {:ok, %Mnemosyne.LLM.Response{content: "mock response", model: "mock:test", usage: %{}}}
    end)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, fn _msgs, _schema, _opts ->
      {:ok, %Mnemosyne.LLM.Response{content: %{}, model: "mock:test", usage: %{}}}
    end)

    project_id = "api-latest-test-" <> Integer.to_string(System.unique_integer([:positive]))
    {:ok, _} = Gingko.Memory.open_project(project_id)

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
    end)

    %{project_id: project_id}
  end

  describe "GET /api/projects/:project_id/latest" do
    test "returns latest memories", %{conn: conn, project_id: project_id} do
      node = %Semantic{
        id: "node-1",
        proposition: "test content",
        confidence: 0.9
      }

      meta = %NodeMetadata{created_at: DateTime.utc_now()}

      stub(Mnemosyne, :latest, fn _repo_id, _top_k, _opts ->
        {:ok, [{node, meta}]}
      end)

      conn = get(conn, "/api/projects/#{project_id}/latest")
      body = json_response(conn, 200)
      assert body["project_id"] == project_id
      assert [%{"node" => node_data, "metadata" => _meta}] = body["memories"]
      assert node_data["id"] == "node-1"
      assert node_data["proposition"] == "test content"
    end

    test "accepts top_k parameter", %{conn: conn, project_id: project_id} do
      stub(Mnemosyne, :latest, fn _repo_id, top_k, _opts ->
        assert top_k == 5
        {:ok, []}
      end)

      conn = get conn, "/api/projects/#{project_id}/latest", %{"top_k" => "5"}
      body = json_response(conn, 200)
      assert body["memories"] == []
    end

    test "returns markdown format when requested", %{conn: conn, project_id: project_id} do
      node = %Semantic{
        id: "node-1",
        proposition: "test content",
        confidence: 0.9
      }

      meta = %NodeMetadata{created_at: DateTime.utc_now()}

      stub(Mnemosyne, :latest, fn _repo_id, _top_k, _opts ->
        {:ok, [{node, meta}]}
      end)

      conn = get conn, "/api/projects/#{project_id}/latest", %{"format" => "markdown"}
      body = json_response(conn, 200)
      assert body["format"] == "markdown"
      assert body["content"] =~ "### Memory"
      assert body["content"] =~ "test content"
      assert body["content"] =~ "Semantic"
    end

    test "returns 404 for project not open", %{conn: conn} do
      conn = get(conn, "/api/projects/not-open-project/latest")
      assert json_response(conn, 404)["error"]["code"] == "project_not_open"
    end
  end
end
