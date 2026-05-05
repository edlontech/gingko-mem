defmodule Gingko.Cost.TelemetryHandlerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Gingko.Cost.Context
  alias Gingko.Cost.Recorder
  alias Gingko.Cost.TelemetryHandler

  setup :set_mimic_global

  setup do
    test_pid = self()

    stub(Recorder, :record, fn row ->
      send(test_pid, {:recorded, row})
      :ok
    end)

    :ok = TelemetryHandler.attach()
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  defp emit_request_stop(usage) do
    :telemetry.execute(
      [:sycophant, :request, :stop],
      %{duration: System.convert_time_unit(123, :millisecond, :native)},
      %{
        model: "gpt-4o",
        provider: :openai,
        wire_protocol: :openai_chat,
        usage: usage,
        response_model: "gpt-4o-2024-08-06",
        response_id: "resp_123",
        finish_reason: :stop
      }
    )
  end

  test "request :stop with full usage produces a complete row" do
    usage = %{
      input_tokens: 10,
      output_tokens: 20,
      input_cost: 0.0001,
      output_cost: 0.0004,
      total_cost: 0.0005,
      pricing: %{currency: "USD"}
    }

    Context.with(%{project_key: "demo", feature: :step_summarization}, fn ->
      emit_request_stop(usage)
    end)

    assert_receive {:recorded, row}
    assert row.event_kind == "request"
    assert row.status == "ok"
    assert row.model == "gpt-4o"
    assert row.provider == "openai"
    assert row.duration_ms == 123
    assert row.input_tokens == 10
    assert row.total_cost == 0.0005
    assert row.currency == "USD"
    assert row.project_key == "demo"
    assert row.feature == "step_summarization"
  end

  test "request :stop with usage = nil records tokens/costs as nil" do
    emit_request_stop(nil)

    assert_receive {:recorded, row}
    assert row.input_tokens == nil
    assert row.total_cost == nil
    assert row.currency == nil
  end

  test "usage without pricing yields nil currency and nil total_cost" do
    emit_request_stop(%{input_tokens: 10, total_cost: nil})

    assert_receive {:recorded, row}
    assert row.input_tokens == 10
    assert row.total_cost == nil
    assert row.currency == nil
  end

  test "request :error builds a row with status=error" do
    :telemetry.execute(
      [:sycophant, :request, :error],
      %{duration: System.convert_time_unit(50, :millisecond, :native)},
      %{
        model: "gpt-4o",
        provider: :openai,
        wire_protocol: :openai_chat,
        error: %{message: "boom"},
        error_class: :upstream
      }
    )

    assert_receive {:recorded, row}
    assert row.status == "error"
    assert row.error_class == "upstream"
  end

  test "embedding :stop event yields event_kind = embedding" do
    :telemetry.execute(
      [:sycophant, :embedding, :stop],
      %{duration: System.convert_time_unit(10, :millisecond, :native)},
      %{
        model: "text-embedding-3-small",
        provider: :openai,
        wire_protocol: :openai_embedding,
        usage: %{input_tokens: 5}
      }
    )

    assert_receive {:recorded, row}
    assert row.event_kind == "embedding"
    assert row.input_tokens == 5
  end

  test "malformed metadata is logged and dropped without raising" do
    me = self()

    spawn_link(fn ->
      :telemetry.execute(
        [:sycophant, :request, :stop],
        %{duration: "not-an-integer"},
        %{model: "gpt-4o"}
      )

      send(me, :survived)
    end)

    assert_receive :survived, 200
  end
end
