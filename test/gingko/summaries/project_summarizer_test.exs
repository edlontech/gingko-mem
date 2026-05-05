defmodule Gingko.Summaries.ProjectSummarizerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Gingko.Summaries.ProjectSummarizer

  setup :set_mimic_global

  setup do
    Mimic.copy(Sycophant)
    :ok
  end

  describe "summarize/2" do
    test "returns the LLM-extracted content and frontmatter on success" do
      stub(Sycophant, :generate_object, fn _model, _messages, _schema ->
        {:ok,
         %{
           object: %{
             content: "## Current focus\n\nA constitution.",
             frontmatter: %{topics: ["focus"], key_concepts: ["module"]}
           }
         }}
      end)

      memories = [%{node: %{proposition: "we built a thing"}}]

      assert {:ok, %{content: content, frontmatter: %{topics: ["focus"]}}} =
               ProjectSummarizer.summarize(memories, "ship small")

      assert content =~ "Current focus"
    end

    test "passes the charter into the user message when provided" do
      test_pid = self()

      stub(Sycophant, :generate_object, fn _model, messages, _schema ->
        send(test_pid, {:messages, messages})

        {:ok,
         %{
           object: %{content: "body", frontmatter: %{topics: [], key_concepts: []}}
         }}
      end)

      _ = ProjectSummarizer.summarize([], "charter content here")

      assert_receive {:messages, messages}
      user_message = List.last(messages)
      assert user_message.content =~ "Project charter:"
      assert user_message.content =~ "charter content here"
    end

    test "omits charter section when nil" do
      test_pid = self()

      stub(Sycophant, :generate_object, fn _model, messages, _schema ->
        send(test_pid, {:messages, messages})

        {:ok,
         %{
           object: %{content: "body", frontmatter: %{topics: [], key_concepts: []}}
         }}
      end)

      _ = ProjectSummarizer.summarize([], nil)

      assert_receive {:messages, messages}
      user_message = List.last(messages)
      refute user_message.content =~ "Project charter:"
    end

    test "renders a placeholder line when memories list is empty" do
      test_pid = self()

      stub(Sycophant, :generate_object, fn _model, messages, _schema ->
        send(test_pid, {:messages, messages})

        {:ok,
         %{
           object: %{content: "body", frontmatter: %{topics: [], key_concepts: []}}
         }}
      end)

      _ = ProjectSummarizer.summarize([], nil)

      assert_receive {:messages, messages}
      user_message = List.last(messages)
      assert user_message.content =~ "Durable knowledge"
      assert user_message.content =~ "Recent events"
      assert user_message.content =~ "(none)"
    end

    test "splits a flat list into semantic and episodic groups by node shape" do
      test_pid = self()

      stub(Sycophant, :generate_object, fn _model, messages, _schema ->
        send(test_pid, {:messages, messages})

        {:ok,
         %{object: %{content: "body", frontmatter: %{topics: [], key_concepts: []}}}}
      end)

      memories = [
        %{node: %{proposition: "stable truth"}},
        %{node: %{observation: "saw x", action: "did y"}}
      ]

      _ = ProjectSummarizer.summarize(memories, nil)

      assert_receive {:messages, messages}
      content = List.last(messages).content
      [_, durable_block, episodic_block] =
        Regex.run(
          ~r/Durable knowledge[^\n]*\n(.*?)Recent events[^\n]*\n(.*?)Distill/s,
          content
        )

      assert durable_block =~ "stable truth"
      refute durable_block =~ "saw x"
      assert episodic_block =~ "saw x -> did y"
      refute episodic_block =~ "stable truth"
    end

    test "accepts a categorized inputs map" do
      test_pid = self()

      stub(Sycophant, :generate_object, fn _model, messages, _schema ->
        send(test_pid, {:messages, messages})

        {:ok,
         %{object: %{content: "body", frontmatter: %{topics: [], key_concepts: []}}}}
      end)

      _ =
        ProjectSummarizer.summarize(
          %{
            semantic: [%{node: %{proposition: "S"}}],
            episodic: [%{node: %{observation: "O", action: "A"}}]
          },
          nil
        )

      assert_receive {:messages, messages}
      content = List.last(messages).content
      assert content =~ "Durable knowledge"
      assert content =~ "- S"
      assert content =~ "- O -> A"
    end

    test "propagates LLM errors" do
      stub(Sycophant, :generate_object, fn _model, _messages, _schema ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} = ProjectSummarizer.summarize([], nil)
    end
  end
end
