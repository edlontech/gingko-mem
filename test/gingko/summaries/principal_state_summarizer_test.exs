defmodule Gingko.Summaries.PrincipalStateSummarizerTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Gingko.Summaries.ClusterSummary
  alias Gingko.Summaries.PrincipalStateSummarizer
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

  describe "summarize/2" do
    test "returns the structured frontmatter from the LLM response" do
      clusters = [
        %ClusterSummary{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10,
          headline: "auth headline"
        }
      ]

      llm_body = %{
        "content" => "state body",
        "frontmatter" => %{
          "topics" => ["Authentication", "Storage"],
          "key_concepts" => ["session token", "principal state"]
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

      assert {:ok, result} = PrincipalStateSummarizer.summarize(clusters, nil)
      assert result.content == "state body"

      normalized = stringify_map_keys(result.frontmatter)
      assert normalized["topics"] == ["Authentication", "Storage"]
      assert normalized["key_concepts"] == ["session token", "principal state"]
    end
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_map_keys(v)} end)
  end

  defp stringify_map_keys(list) when is_list(list), do: Enum.map(list, &stringify_map_keys/1)
  defp stringify_map_keys(other), do: other
end
