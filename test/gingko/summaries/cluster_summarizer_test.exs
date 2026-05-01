defmodule Gingko.Summaries.ClusterSummarizerTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Gingko.Summaries.ClusterSummarizer
  alias Gingko.Summaries.ClusterSummary
  alias Sycophant.Context
  alias Sycophant.Pipeline
  alias Sycophant.Response
  alias Sycophant.ResponseValidator
  alias Sycophant.Schema.Normalizer

  setup :set_mimic_private

  setup do
    Mimic.copy(Pipeline)
    :ok
  end

  describe "summarize/3" do
    test "returns the structured frontmatter from the LLM response" do
      cluster = %ClusterSummary{
        project_key: "p",
        tag_node_id: "t",
        tag_label: "Auth",
        slug: "auth",
        memory_count: 40,
        regen_count: 5,
        content: "old"
      }

      llm_body = %{
        "headline" => "new headline",
        "content" => "new content body",
        "frontmatter" => %{
          "subtopics" => ["session tokens", "OAuth callback"],
          "key_entities" => ["AuthController", "Guardian"]
        }
      }

      raw_text = JSON.encode!(llm_body)

      expect(Pipeline, :call, fn _messages, opts ->
        schema = Keyword.fetch!(opts, :response_schema)
        {:ok, normalized} = Normalizer.normalize(schema)

        response = %Response{
          text: raw_text,
          context: %Context{messages: []},
          model: Keyword.get(opts, :model)
        }

        ResponseValidator.validate(response, normalized, true)
      end)

      assert {:ok, result} = ClusterSummarizer.summarize(cluster, [], :full)
      assert result.headline == "new headline"
      assert result.content == "new content body"

      normalized = stringify_map_keys(result.frontmatter)
      assert normalized["subtopics"] == ["session tokens", "OAuth callback"]
      assert normalized["key_entities"] == ["AuthController", "Guardian"]
    end
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_map_keys(v)} end)
  end

  defp stringify_map_keys(list) when is_list(list), do: Enum.map(list, &stringify_map_keys/1)
  defp stringify_map_keys(other), do: other
end
