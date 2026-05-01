defmodule Gingko.MCP.Tools.GetSessionPrimerTest do
  use Gingko.DataCase, async: false

  alias Anubis.Server.Frame
  alias Gingko.MCP.Tools.GetSessionPrimer
  alias Gingko.Summaries

  setup do
    Application.put_env(:gingko, Gingko.Summaries.Config,
      enabled: true,
      session_primer_recent_count: 5
    )

    on_exit(fn -> Application.delete_env(:gingko, Gingko.Summaries.Config) end)

    :ok
  end

  describe "execute/2" do
    test "returns the composed primer as text content with all regions when populated" do
      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "Charter prose."
        })

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "summary",
          content: "Project is in alpha."
        })

      {:reply, response, _frame} =
        GetSessionPrimer.execute(%{"project_id" => "p"}, Frame.new())

      text = text_content(response)

      assert text =~ "region:playbook"
      assert text =~ "region:charter"
      assert text =~ "region:summary"
      assert text =~ "region:recent_memories"
      assert text =~ "Project is in alpha."
      assert text =~ "Charter prose."
    end

    test "omits the charter region when no charter row exists" do
      {:reply, response, _frame} =
        GetSessionPrimer.execute(%{"project_id" => "p"}, Frame.new())

      refute text_content(response) =~ "region:charter"
    end

    test "honors recent_count argument by passing it to render_primer" do
      {:reply, response, _frame} =
        GetSessionPrimer.execute(
          %{"project_id" => "p", "recent_count" => 3},
          Frame.new()
        )

      text = text_content(response)
      assert is_binary(text)
      assert text =~ "region:recent_memories"
    end

    test "returns an invalid_params error when recent_count is a non-numeric string" do
      {:reply, response, _frame} =
        GetSessionPrimer.execute(
          %{"project_id" => "p", "recent_count" => "abc"},
          Frame.new()
        )

      assert response.isError == true
      assert %{"error" => %{"code" => "invalid_params"}} = response.structured_content
    end
  end

  defp text_content(response) do
    [%{"type" => "text", "text" => text}] = response.content
    text
  end
end
