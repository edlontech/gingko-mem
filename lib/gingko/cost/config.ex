defmodule Gingko.Cost.Config do
  @moduledoc """
  Config accessor for the cost tracker. Reads from
  `Application.get_env(:gingko, __MODULE__)`. Stub via Mimic in tests instead
  of mutating application env.
  """

  @defaults [
    enabled: true,
    retention_days: 0,
    batch_size_max: 50,
    flush_interval_ms: 500
  ]

  @spec enabled?() :: boolean()
  def enabled?, do: get(:enabled)

  @spec retention_days() :: non_neg_integer()
  def retention_days, do: get(:retention_days)

  @spec batch_size_max() :: pos_integer()
  def batch_size_max, do: get(:batch_size_max)

  @spec flush_interval_ms() :: pos_integer()
  def flush_interval_ms, do: get(:flush_interval_ms)

  defp get(key) do
    :gingko
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
