defmodule Gingko.SummariesTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Memory
  alias Gingko.Summaries
  alias Gingko.Summaries.PrincipalMemorySection

  setup :set_mimic_global

  describe "principal sections" do
    test "upsert_section inserts then replaces by (project_key, kind)" do
      assert {:ok, %PrincipalMemorySection{id: first_id}} =
               Summaries.upsert_section(%{
                 project_key: "p",
                 kind: "summary",
                 content: "v1"
               })

      assert {:ok, %PrincipalMemorySection{id: second_id}} =
               Summaries.upsert_section(%{
                 project_key: "p",
                 kind: "summary",
                 content: "v2"
               })

      assert first_id == second_id
      assert %{content: "v2"} = Summaries.get_section("p", "summary")
    end

    test "rejects unknown kind" do
      assert {:error, changeset} =
               Summaries.upsert_section(%{
                 project_key: "p",
                 kind: "bogus",
                 content: ""
               })

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "list_sections scopes to project_key" do
      {:ok, _} =
        Summaries.upsert_section(%{project_key: "a", kind: "summary", content: "A"})

      {:ok, _} =
        Summaries.upsert_section(%{project_key: "b", kind: "summary", content: "B"})

      assert [%{project_key: "a"}] = Summaries.list_sections("a")
    end

    test "get_section returns nil when missing" do
      refute Summaries.get_section("p", "charter")
    end
  end

  describe "set_charter/2" do
    test "rejects empty content" do
      assert {:error, %{code: :invalid_params}} = Summaries.set_charter("p", "")
      assert {:error, %{code: :invalid_params}} = Summaries.set_charter("p", nil)
    end

    test "refuses to overwrite a locked charter" do
      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "original",
          locked: true
        })

      assert {:error, %{code: :charter_locked}} = Summaries.set_charter("p", "new content")
      assert %{content: "original"} = Summaries.get_section("p", "charter")
    end

    test "writes charter content when unlocked" do
      assert {:ok, %{content: "shipped"}} = Summaries.set_charter("p", "shipped")
      assert %{content: "shipped"} = Summaries.get_section("p", "charter")
    end
  end

  describe "render_primer/2" do
    setup do
      Mimic.copy(Gingko.Memory)
      :ok
    end

    test "renders charter, summary, and recent memories" do
      project_key = "primer-happy-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "charter",
          content: "Ship it small."
        })

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "summary",
          content: "## What we're working on\n\nThe constitution body."
        })

      stub(Memory, :latest_memories, fn %{project_id: ^project_key} ->
        {:ok,
         %{
           project_id: project_key,
           memories: [
             %{
               node: %{type: "semantic", proposition: "tail memory body"},
               metadata: %{created_at: ~U[2026-04-20 12:00:00Z]}
             }
           ]
         }}
      end)

      assert {:ok, rendered} = Summaries.render_primer(project_key)

      assert rendered =~ "Gingko Memory — Recall Playbook"
      assert rendered =~ "Ship it small."
      assert rendered =~ "constitution body"
      assert rendered =~ "tail memory body"
      assert rendered =~ "<!-- region:recent_memories -->"
    end

    test "includes the static playbook even when no sections exist" do
      project_key = "primer-empty-#{System.unique_integer([:positive])}"

      stub(Memory, :latest_memories, fn %{project_id: ^project_key} ->
        {:ok, %{project_id: project_key, memories: []}}
      end)

      assert {:ok, rendered} = Summaries.render_primer(project_key)

      assert rendered =~ "Gingko Memory — Recall Playbook"
      assert rendered =~ "_Not yet generated._"
      assert rendered =~ "_No recent memories._"
    end

    test "renders empty recent tail when Memory.latest_memories/1 errors" do
      project_key = "primer-errors-#{System.unique_integer([:positive])}"

      stub(Memory, :latest_memories, fn %{project_id: ^project_key} ->
        {:error, %{code: :project_not_open, message: "repo not open"}}
      end)

      assert {:ok, rendered} = Summaries.render_primer(project_key)

      assert rendered =~ "<!-- region:recent_memories -->"
      assert rendered =~ "_No recent memories._"
    end
  end
end
