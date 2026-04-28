defmodule Gingko.Summaries.ConfigTest do
  use ExUnit.Case, async: false

  alias Gingko.Summaries.Config

  setup do
    original = Application.get_env(:gingko, Config)
    Application.delete_env(:gingko, Config)

    on_exit(fn ->
      if original do
        Application.put_env(:gingko, Config, original)
      else
        Application.delete_env(:gingko, Config)
      end
    end)

    :ok
  end

  test "returns documented defaults when no override is configured" do
    refute Config.enabled?()
    assert Config.hot_tags_k() == 15
    assert Config.cluster_regen_memory_threshold() == 10
    assert Config.cluster_regen_idle_seconds() == 1800
    assert Config.principal_regen_debounce_seconds() == 60
    assert Config.session_primer_recent_count() == 15
  end

  test "reads values from application env overrides" do
    Application.put_env(:gingko, Config,
      enabled: true,
      hot_tags_k: 7,
      cluster_regen_memory_threshold: 3,
      cluster_regen_idle_seconds: 120,
      principal_regen_debounce_seconds: 30,
      session_primer_recent_count: 5
    )

    assert Config.enabled?()
    assert Config.hot_tags_k() == 7
    assert Config.cluster_regen_memory_threshold() == 3
    assert Config.cluster_regen_idle_seconds() == 120
    assert Config.principal_regen_debounce_seconds() == 30
    assert Config.session_primer_recent_count() == 5
  end

  test "all/0 returns a fully resolved map" do
    Application.put_env(:gingko, Config, enabled: true, hot_tags_k: 9)

    assert Config.all() == %{
             enabled: true,
             hot_tags_k: 9,
             cluster_regen_memory_threshold: 10,
             cluster_regen_idle_seconds: 1800,
             principal_regen_debounce_seconds: 60,
             session_primer_recent_count: 15,
             chunk_chars: 512_000,
             max_chunks: 8,
             parallelism: 4,
             chunk_timeout_ms: 60_000
           }
  end

  test "partial overrides fall back to defaults for remaining keys" do
    Application.put_env(:gingko, Config, hot_tags_k: 25)

    refute Config.enabled?()
    assert Config.hot_tags_k() == 25
    assert Config.cluster_regen_memory_threshold() == 10
  end
end
