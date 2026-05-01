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
    assert Config.regen_debounce_seconds() == 60
    assert Config.summary_memory_count() == 200
    assert Config.session_primer_recent_count() == 15
  end

  test "reads values from application env overrides" do
    Application.put_env(:gingko, Config,
      enabled: true,
      regen_debounce_seconds: 30,
      summary_memory_count: 100,
      session_primer_recent_count: 5
    )

    assert Config.enabled?()
    assert Config.regen_debounce_seconds() == 30
    assert Config.summary_memory_count() == 100
    assert Config.session_primer_recent_count() == 5
  end

  test "all/0 returns a fully resolved map" do
    Application.put_env(:gingko, Config, enabled: true, summary_memory_count: 9)

    assert Config.all() == %{
             enabled: true,
             regen_debounce_seconds: 60,
             summary_memory_count: 9,
             session_primer_recent_count: 15,
             chunk_chars: 512_000,
             max_chunks: 8,
             parallelism: 4,
             chunk_timeout_ms: 60_000
           }
  end

  test "partial overrides fall back to defaults for remaining keys" do
    Application.put_env(:gingko, Config, summary_memory_count: 25)

    refute Config.enabled?()
    assert Config.summary_memory_count() == 25
    assert Config.regen_debounce_seconds() == 60
  end
end
