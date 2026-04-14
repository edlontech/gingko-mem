defmodule GingkoWeb.Api.ProjectControllerTest do
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

    :ok
  end

  describe "GET /api/projects" do
    test "returns project list", %{conn: conn} do
      conn = get(conn, "/api/projects")
      assert %{"projects" => projects} = json_response(conn, 200)
      assert is_list(projects)
    end
  end

  describe "POST /api/projects/:project_id/open" do
    test "opens a project and returns result", %{conn: conn} do
      project_id = "api-test-" <> Integer.to_string(System.unique_integer([:positive]))

      on_exit(fn ->
        repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
        if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
      end)

      conn = post(conn, "/api/projects/#{project_id}/open")
      body = json_response(conn, 200)
      assert body["project_id"] == project_id
      assert body["already_open"] == false
      assert is_binary(body["repo_id"])
      refute Map.has_key?(body, "already_open?")
    end

    test "open is idempotent", %{conn: conn} do
      project_id = "api-test-" <> Integer.to_string(System.unique_integer([:positive]))

      on_exit(fn ->
        repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
        if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
      end)

      post(conn, "/api/projects/#{project_id}/open")
      conn = post(conn, "/api/projects/#{project_id}/open")
      assert json_response(conn, 200)["already_open"] == true
    end
  end
end
