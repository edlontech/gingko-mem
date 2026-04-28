defmodule Gingko.Memory.SummarizerTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Gingko.Memory.Summarizer
  alias Gingko.Summaries.Config

  setup :set_mimic_private

  setup do
    Mimic.copy(Sycophant)
    Mimic.copy(Config)
    :ok
  end

  describe "chunk/2" do
    test "returns single chunk when content fits" do
      assert Summarizer.chunk("hello world", 100) == ["hello world"]
    end

    test "splits on line boundaries when content exceeds max_chars" do
      content = Enum.map_join(1..6, "\n", &"line-#{&1}")
      chunks = Summarizer.chunk(content, 14)

      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1) <= 20))
      assert Enum.join(chunks, "\n") == content
    end

    test "emits an oversized line as its own chunk without splitting" do
      huge = String.duplicate("a", 50)
      content = "small\n" <> huge <> "\nsmall"

      chunks = Summarizer.chunk(content, 10)

      assert huge in chunks
    end
  end

  describe "extract/1" do
    test "rejects empty content" do
      assert {:error, :empty_content} = Summarizer.extract("")
    end

    test "single-chunk path returns the LLM object directly" do
      stub_summaries_config(chunk_chars: 10_000)

      expect(Sycophant, :generate_object, fn _model, _messages, _schema ->
        {:ok, %{object: %{observation: "obs", action: "act"}}}
      end)

      assert {:ok, %{observation: "obs", action: "act"}} =
               Summarizer.extract("a small input")
    end

    test "multi-chunk path runs map then reduce" do
      stub_summaries_config(
        chunk_chars: 10,
        max_chunks: 8,
        parallelism: 2,
        chunk_timeout_ms: 5_000
      )

      content =
        Enum.map_join(1..6, "\n", fn idx ->
          String.duplicate("x", 12) <> "-#{idx}"
        end)

      this = self()

      stub(Sycophant, :generate_object, fn _model, messages, _schema ->
        send(this, {:call, classify(messages)})

        case classify(messages) do
          :map -> {:ok, %{object: %{observation: "chunk obs", action: "chunk act"}}}
          :reduce -> {:ok, %{object: %{observation: "final obs", action: "final act"}}}
        end
      end)

      assert {:ok, %{observation: "final obs", action: "final act"}} =
               Summarizer.extract(content)

      calls = collect_calls()
      assert Enum.count(calls, &(&1 == :map)) >= 2
      assert Enum.count(calls, &(&1 == :reduce)) == 1
    end

    test "falls back to first successful pair when reduce fails" do
      stub_summaries_config(
        chunk_chars: 10,
        max_chunks: 8,
        parallelism: 2,
        chunk_timeout_ms: 5_000
      )

      content = String.duplicate("xxxxxxxxxx\n", 4)

      stub(Sycophant, :generate_object, fn _model, messages, _schema ->
        case classify(messages) do
          :map -> {:ok, %{object: %{observation: "first", action: "first act"}}}
          :reduce -> {:error, :rate_limited}
        end
      end)

      assert {:ok, %{observation: "first", action: "first act"}} =
               Summarizer.extract(content)
    end

    test "returns :all_chunks_failed when every map call errors" do
      stub_summaries_config(
        chunk_chars: 10,
        max_chunks: 8,
        parallelism: 2,
        chunk_timeout_ms: 5_000
      )

      content = String.duplicate("xxxxxxxxxx\n", 4)

      stub(Sycophant, :generate_object, fn _model, _messages, _schema ->
        {:error, :boom}
      end)

      assert {:error, :all_chunks_failed} = Summarizer.extract(content)
    end
  end

  defp classify(messages) do
    case Enum.find(messages, &match?(%{role: :system}, &1)) do
      %{content: content} ->
        if String.contains?(content, "consolidation"), do: :reduce, else: :map

      _ ->
        :map
    end
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:call, kind} -> collect_calls([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp stub_summaries_config(overrides) do
    for {key, value} <- overrides do
      stub(Config, key, fn -> value end)
    end
  end
end
