defmodule Gingko.MCP.Tools.SetCharterTest do
  use Gingko.DataCase, async: false

  alias Anubis.Server.Frame
  alias Gingko.MCP.Tools.SetCharter
  alias Gingko.Summaries

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)
    on_exit(fn -> Application.delete_env(:gingko, Gingko.Summaries.Config) end)
    :ok
  end

  describe "execute/2" do
    test "inserts a new charter row" do
      {:reply, response, _frame} =
        SetCharter.execute(
          %{"project_id" => "p", "content" => "Be excellent."},
          Frame.new()
        )

      refute Map.get(response, :isError)
      assert response.structured_content["kind"] == "charter"
      assert response.structured_content["content"] == "Be excellent."

      assert %{content: "Be excellent."} = Summaries.get_section("p", "charter")
    end

    test "replaces the existing charter content" do
      {:ok, _} =
        Summaries.upsert_section(%{project_key: "p", kind: "charter", content: "old"})

      {:reply, response, _frame} =
        SetCharter.execute(
          %{"project_id" => "p", "content" => "new"},
          Frame.new()
        )

      refute Map.get(response, :isError)
      assert Summaries.get_section("p", "charter").content == "new"
    end

    test "rejects when the existing charter is locked without overwriting" do
      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "pinned",
          locked: true
        })

      {:reply, response, _frame} =
        SetCharter.execute(
          %{"project_id" => "p", "content" => "overwrite?"},
          Frame.new()
        )

      assert response.isError == true
      assert %{"error" => %{"code" => "charter_locked"}} = response.structured_content
      assert Summaries.get_section("p", "charter").content == "pinned"
    end

    test "requires non-empty content" do
      {:reply, response, _frame} =
        SetCharter.execute(%{"project_id" => "p", "content" => ""}, Frame.new())

      assert response.isError == true
      assert %{"error" => %{"code" => "invalid_params"}} = response.structured_content
    end
  end
end
