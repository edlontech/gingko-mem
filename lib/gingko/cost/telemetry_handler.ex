defmodule Gingko.Cost.TelemetryHandler do
  @moduledoc """
  Subscribes to Sycophant's request and embedding telemetry, builds a
  `Cost.Call`-shaped row tagged with the caller's `Cost.Context`, and casts
  it to `Cost.Recorder`. The handler never propagates exceptions to the
  caller.
  """

  require Logger

  alias Gingko.Cost.Context
  alias Gingko.Cost.Recorder

  @handler_id "gingko-cost"

  @events [
    [:sycophant, :request, :stop],
    [:sycophant, :request, :error],
    [:sycophant, :embedding, :stop],
    [:sycophant, :embedding, :error]
  ]

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    try do
      row = build_row(event, measurements, metadata)
      Recorder.record(row)
    rescue
      e ->
        Logger.warning(
          "Cost.TelemetryHandler dropped row for #{inspect(event)}: #{Exception.message(e)}"
        )
    end
  end

  defp build_row([:sycophant, kind, outcome], measurements, metadata) do
    base_row(kind, outcome, measurements, metadata)
    |> Map.merge(usage_fields(metadata[:usage]))
    |> Map.merge(context_fields(Context.current()))
  end

  defp base_row(kind, outcome, measurements, metadata) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      occurred_at: now,
      inserted_at: now,
      event_kind: Atom.to_string(kind),
      status: status_for(outcome),
      model: metadata[:model] || "(unknown)",
      provider: stringify(metadata[:provider]),
      wire_protocol: stringify(metadata[:wire_protocol]),
      response_id: metadata[:response_id],
      response_model: metadata[:response_model],
      finish_reason: stringify(metadata[:finish_reason]),
      error_class: stringify(metadata[:error_class]),
      duration_ms: duration_ms(measurements[:duration])
    }
  end

  defp status_for(:stop), do: "ok"
  defp status_for(:error), do: "error"

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(other), do: inspect(other)

  defp duration_ms(nil), do: nil

  defp duration_ms(native) when is_integer(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end

  defp duration_ms(_), do: nil

  defp usage_fields(nil), do: empty_usage()

  defp usage_fields(%{} = usage) do
    %{
      input_tokens: usage[:input_tokens],
      output_tokens: usage[:output_tokens],
      cache_read_input_tokens: usage[:cache_read_input_tokens],
      cache_creation_input_tokens: usage[:cache_creation_input_tokens],
      reasoning_tokens: usage[:reasoning_tokens],
      input_cost: usage[:input_cost],
      output_cost: usage[:output_cost],
      cache_read_cost: usage[:cache_read_cost],
      cache_write_cost: usage[:cache_write_cost],
      reasoning_cost: usage[:reasoning_cost],
      total_cost: usage[:total_cost],
      currency: currency_of(usage[:pricing])
    }
  end

  defp empty_usage do
    %{
      input_tokens: nil,
      output_tokens: nil,
      cache_read_input_tokens: nil,
      cache_creation_input_tokens: nil,
      reasoning_tokens: nil,
      input_cost: nil,
      output_cost: nil,
      cache_read_cost: nil,
      cache_write_cost: nil,
      reasoning_cost: nil,
      total_cost: nil,
      currency: nil
    }
  end

  defp currency_of(nil), do: nil
  defp currency_of(%{currency: currency}), do: currency
  defp currency_of(_), do: nil

  defp context_fields(ctx) do
    %{
      project_key: ctx[:project_key],
      session_id: ctx[:session_id],
      feature: stringify(ctx[:feature])
    }
  end
end
