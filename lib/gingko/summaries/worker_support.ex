defmodule Gingko.Summaries.WorkerSupport do
  @moduledoc false

  alias Gingko.Summaries.Config

  @spec if_enabled((-> term())) :: term() | {:discard, String.t()}
  def if_enabled(fun) when is_function(fun, 0) do
    if Config.enabled?(), do: fun.(), else: {:discard, "summaries disabled"}
  end

  @spec with_duration((-> term())) :: {term(), non_neg_integer()}
  def with_duration(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - start}
  end

  @spec emit([atom()], non_neg_integer(), map()) :: :ok
  def emit(event, duration_ms, metadata) do
    :telemetry.execute(event, %{duration_ms: duration_ms}, metadata)
  end
end
