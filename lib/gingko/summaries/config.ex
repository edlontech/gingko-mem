defmodule Gingko.Summaries.Config do
  @moduledoc """
  Read-only view over the `[summaries]` section of `config.toml`, exposed as
  discrete accessors with documented defaults.
  """

  @defaults %{
    enabled: false,
    hot_tags_k: 15,
    cluster_regen_memory_threshold: 10,
    cluster_regen_idle_seconds: 1800,
    principal_regen_debounce_seconds: 60,
    session_primer_recent_count: 15,
    chunk_chars: 512_000,
    max_chunks: 8,
    parallelism: 4,
    chunk_timeout_ms: 60_000
  }

  @doc "Default values used when the `[summaries]` section is absent."
  def defaults, do: @defaults

  def enabled?, do: fetch(:enabled)
  def hot_tags_k, do: fetch(:hot_tags_k)
  def cluster_regen_memory_threshold, do: fetch(:cluster_regen_memory_threshold)
  def cluster_regen_idle_seconds, do: fetch(:cluster_regen_idle_seconds)
  def principal_regen_debounce_seconds, do: fetch(:principal_regen_debounce_seconds)
  def session_primer_recent_count, do: fetch(:session_primer_recent_count)
  def chunk_chars, do: fetch(:chunk_chars)
  def max_chunks, do: fetch(:max_chunks)
  def parallelism, do: fetch(:parallelism)
  def chunk_timeout_ms, do: fetch(:chunk_timeout_ms)

  @doc "Returns every configured value (with defaults applied) as a map."
  def all, do: Map.new(@defaults, fn {key, _default} -> {key, fetch(key)} end)

  defp fetch(key) do
    :gingko
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Map.fetch!(@defaults, key))
  end
end
