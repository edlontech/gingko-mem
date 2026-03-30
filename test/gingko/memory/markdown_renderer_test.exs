defmodule Gingko.Memory.MarkdownRendererTest do
  use ExUnit.Case, async: true

  alias Gingko.Memory.MarkdownRenderer

  @timestamp ~U[2026-03-20 14:32:01Z]

  defp memory(node_attrs, metadata_attrs \\ %{}) do
    %{
      node: Map.merge(%{id: "node-1", links: [], embedding: nil}, node_attrs),
      metadata:
        Map.merge(
          %{
            created_at: @timestamp,
            access_count: 1,
            cumulative_reward: 0.0,
            reward_count: 0,
            last_accessed_at: @timestamp
          },
          metadata_attrs
        )
    }
  end

  describe "render/1" do
    test "returns no memories message for empty list" do
      assert MarkdownRenderer.render([]) == "No memories found."
    end

    test "renders semantic node with confidence" do
      mem =
        memory(%{
          type: "semantic",
          proposition: "Elixir uses pattern matching.",
          confidence: 0.85
        })

      result = MarkdownRenderer.render([mem])

      assert result =~ "### Memory -- 2026-03-20T14:32:01Z"
      assert result =~ "- **Type:** Semantic"
      assert result =~ "- **Confidence:** 0.85"
      assert result =~ "Elixir uses pattern matching."
    end

    test "renders episodic node" do
      mem =
        memory(%{
          type: "episodic",
          observation: "User reported node_count always showing 0.",
          action: "Updated event notifiers.",
          state: "investigating",
          reward: 1.0
        })

      result = MarkdownRenderer.render([mem])

      assert result =~ "- **Type:** Episodic"
      assert result =~ "**Observation:** User reported node_count always showing 0."
      assert result =~ "**Action:** Updated event notifiers."
    end

    test "renders procedural node" do
      mem =
        memory(%{
          type: "procedural",
          instruction: "Run mix test before committing.",
          condition: "Code changes made",
          expected_outcome: "All tests pass"
        })

      result = MarkdownRenderer.render([mem])

      assert result =~ "- **Type:** Procedural"
      assert result =~ "**Instruction:** Run mix test before committing."
      assert result =~ "**Condition:** Code changes made"
      assert result =~ "**Expected Outcome:** All tests pass"
    end

    test "renders intent node" do
      mem = memory(%{type: "intent", description: "Implement markdown rendering for memories."})

      result = MarkdownRenderer.render([mem])

      assert result =~ "- **Type:** Intent"
      assert result =~ "Implement markdown rendering for memories."
    end

    test "renders subgoal node with parent" do
      mem =
        memory(%{
          type: "subgoal",
          description: "Create renderer module.",
          parent_goal: "goal-123"
        })

      result = MarkdownRenderer.render([mem])

      assert result =~ "- **Type:** Subgoal"
      assert result =~ "Create renderer module."
      assert result =~ "**Parent Goal:** goal-123"
    end

    test "renders subgoal node without parent" do
      mem = memory(%{type: "subgoal", description: "Top-level goal.", parent_goal: nil})

      result = MarkdownRenderer.render([mem])

      assert result =~ "- **Type:** Subgoal"
      assert result =~ "Top-level goal."
      refute result =~ "Parent Goal"
    end

    test "renders tag node" do
      mem = memory(%{type: "tag", label: "important"})

      result = MarkdownRenderer.render([mem])

      assert result =~ "- **Type:** Tag"
      assert result =~ "**Label:** important"
    end

    test "renders source node" do
      mem = memory(%{type: "source", episode_id: "ep-456", step_index: 3})

      result = MarkdownRenderer.render([mem])

      assert result =~ "- **Type:** Source"
      assert result =~ "**Episode:** ep-456"
      assert result =~ "**Step:** 3"
    end

    test "separates multiple memories with horizontal rules" do
      mem1 =
        memory(
          %{type: "semantic", proposition: "First.", confidence: 0.9},
          %{created_at: ~U[2026-03-20 14:32:01Z]}
        )

      mem2 =
        memory(
          %{type: "intent", description: "Second."},
          %{created_at: ~U[2026-03-20 14:30:15Z]}
        )

      result = MarkdownRenderer.render([mem1, mem2])

      assert result =~ "First."
      assert result =~ "Second."
      assert result =~ "\n\n---\n\n"
    end

    test "does not show confidence when not numeric" do
      mem = memory(%{type: "semantic", proposition: "No confidence.", confidence: nil})

      result = MarkdownRenderer.render([mem])

      refute result =~ "Confidence"
    end

    test "does not show confidence when not present" do
      mem = memory(%{type: "semantic", proposition: "Missing confidence."})

      result = MarkdownRenderer.render([mem])

      refute result =~ "Confidence"
    end
  end
end
