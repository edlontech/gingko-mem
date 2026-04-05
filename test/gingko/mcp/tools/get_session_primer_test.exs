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
      {:ok, _} = Summaries.seed_playbook("p")

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "state",
          content: "Project is in alpha."
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 12,
          headline: "auth summary",
          dirty: false
        })

      {:reply, response, _frame} =
        GetSessionPrimer.execute(%{"project_id" => "p"}, Frame.new())

      text = text_content(response)

      assert text =~ "region:playbook"
      assert text =~ "region:state"
      assert text =~ "region:cluster_index"
      assert text =~ "region:recent_memories"
      assert text =~ "**auth**"
      assert text =~ "Project is in alpha."
    end

    test "omits the charter region when no charter row exists" do
      {:ok, _} = Summaries.seed_playbook("p")

      {:reply, response, _frame} =
        GetSessionPrimer.execute(%{"project_id" => "p"}, Frame.new())

      refute text_content(response) =~ "region:charter"
    end

    test "orders cluster index by memory_count desc" do
      {:ok, _} = Summaries.seed_playbook("p")

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Small",
          slug: "small",
          memory_count: 2,
          headline: "small topic",
          dirty: false
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Big",
          slug: "big",
          memory_count: 20,
          headline: "big topic",
          dirty: false
        })

      {:reply, response, _frame} =
        GetSessionPrimer.execute(%{"project_id" => "p"}, Frame.new())

      text = text_content(response)
      big_pos = :binary.match(text, "**big**") |> elem(0)
      small_pos = :binary.match(text, "**small**") |> elem(0)

      assert big_pos < small_pos
    end

    test "honors recent_count argument by passing it to render_primer" do
      {:ok, _} = Summaries.seed_playbook("p")

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
      {:ok, _} = Summaries.seed_playbook("p")

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
