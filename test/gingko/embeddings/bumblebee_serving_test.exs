defmodule Gingko.Embeddings.BumblebeeServingTest do
  use ExUnit.Case, async: true

  alias Gingko.Embeddings.BumblebeeServing
  alias Gingko.Settings

  test "child_spec/2 returns a lightweight manager child when bumblebee embeddings are configured" do
    settings = %Settings{
      home: "/tmp/gingko-home",
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "bumblebee", model: "intfloat/e5-base-v2"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        intent_merge_threshold: 0.8,
        intent_identity_threshold: 0.95,
        refinement_threshold: 0.6,
        refinement_budget: 1,
        plateau_delta: 0.05,
        extraction_profile: "none",
        consolidation_threshold: 0.85,
        decay_threshold: 0.1,
        auto_commit: true,
        flush_timeout_ms: 120_000,
        session_timeout_ms: 600_000,
        trace_verbosity: "summary"
      },
      episodic_validation: %{
        validation_threshold: 0.3,
        orphan_penalty: 0.3,
        weak_grounding_penalty: 0.1
      },
      summaries: %{
        enabled: false,
        hot_tags_k: 15,
        cluster_regen_memory_threshold: 10,
        cluster_regen_idle_seconds: 1800,
        principal_regen_debounce_seconds: 60,
        session_primer_recent_count: 15
      },
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    refute_receive _

    assert %{id: BumblebeeServing, start: {BumblebeeServing, :start_link, [opts]}} =
             BumblebeeServing.child_spec(settings)

    assert opts[:model_name] == "intfloat/e5-base-v2"
  end

  test "child_spec/2 returns nil for non-bumblebee embeddings" do
    settings = %Settings{
      home: "/tmp/gingko-home",
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        intent_merge_threshold: 0.8,
        intent_identity_threshold: 0.95,
        refinement_threshold: 0.6,
        refinement_budget: 1,
        plateau_delta: 0.05,
        extraction_profile: "none",
        consolidation_threshold: 0.85,
        decay_threshold: 0.1,
        auto_commit: true,
        flush_timeout_ms: 120_000,
        session_timeout_ms: 600_000,
        trace_verbosity: "summary"
      },
      episodic_validation: %{
        validation_threshold: 0.3,
        orphan_penalty: 0.3,
        weak_grounding_penalty: 0.1
      },
      summaries: %{
        enabled: false,
        hot_tags_k: 15,
        cluster_regen_memory_threshold: 10,
        cluster_regen_idle_seconds: 1800,
        principal_regen_debounce_seconds: 60,
        session_primer_recent_count: 15
      },
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    assert BumblebeeServing.child_spec(settings) == nil
  end

  test "ensure_started/1 builds and starts the serving lazily once" do
    test_pid = self()
    serving = %{fake: :serving}

    builder = fn "intfloat/e5-base-v2" ->
      send(test_pid, :built_serving)
      {:ok, serving}
    end

    starter = fn ^serving, opts ->
      send(test_pid, {:started_serving, opts})
      Agent.start_link(fn -> serving end, name: Keyword.fetch!(opts, :name))
    end

    start_supervised!(
      {BumblebeeServing,
       model_name: "intfloat/e5-base-v2", serving_builder: builder, serving_starter: starter}
    )

    assert {:ok, serving_name} = BumblebeeServing.ensure_started("intfloat/e5-base-v2")
    assert serving_name == BumblebeeServing.name()
    assert_receive :built_serving
    assert_receive {:started_serving, [name: ^serving_name]}

    assert {:ok, ^serving_name} = BumblebeeServing.ensure_started("intfloat/e5-base-v2")
    refute_receive :built_serving
  end

  test "build_serving/2 passes compile and defn compiler options to bumblebee" do
    model_info = %{model: :info}
    tokenizer = %{tokenizer: :info}
    serving = %{serving: :value}

    assert {:ok, ^serving} =
             BumblebeeServing.build_serving("intfloat/e5-base-v2",
               model_loader: fn {:hf, "intfloat/e5-base-v2"} -> {:ok, model_info} end,
               tokenizer_loader: fn {:hf, "intfloat/e5-base-v2"} -> {:ok, tokenizer} end,
               text_embedding_builder: fn ^model_info, ^tokenizer, opts ->
                 assert opts[:compile] == [batch_size: 4, sequence_length: 512]
                 assert opts[:defn_options] == [compiler: EMLX]
                 serving
               end,
               defn_compiler: fn -> EMLX end
             )
  end
end
