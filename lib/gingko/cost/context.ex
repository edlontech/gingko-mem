defmodule Gingko.Cost.Context do
  @moduledoc """
  Per-process attribution stack for LLM cost rows.

  `Gingko.Cost.TelemetryHandler` reads `current/0` synchronously inside the
  Sycophant caller's process and tags the row it builds. Use `with/2` to
  scope attribution to a block; nested calls merge, and the previous map is
  restored on exit (success or raise).
  """

  @key :gingko_cost_context

  @type attrs :: %{
          optional(:project_key) => String.t(),
          optional(:session_id) => String.t(),
          optional(:feature) => atom() | String.t()
        }

  @spec with(attrs(), (-> result)) :: result when result: var
  def with(attrs, fun) when is_map(attrs) and is_function(fun, 0) do
    previous = Process.get(@key, %{})
    Process.put(@key, Map.merge(previous, attrs))

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @spec current() :: attrs()
  def current, do: Process.get(@key, %{})

  defp restore(previous) when previous == %{}, do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end
