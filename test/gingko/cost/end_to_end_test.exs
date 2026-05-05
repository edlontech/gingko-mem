defmodule Gingko.Cost.EndToEndTest do
  use Gingko.DataCase, async: false

  alias Gingko.Cost.Call
  alias Gingko.Cost.Context
  alias Gingko.Cost.Recorder
  alias Gingko.Cost.TelemetryHandler
  alias Gingko.Repo

  setup do
    Repo.delete_all(Call)
    :ok = TelemetryHandler.attach()
    {:ok, _pid} = start_supervised({Recorder, name: Recorder})

    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  test "Cost.Context wrapping yields a row tagged with the right attribution" do
    Context.with(%{project_key: "demo", session_id: "s1", feature: :step_summarization}, fn ->
      :telemetry.execute(
        [:sycophant, :request, :stop],
        %{duration: System.convert_time_unit(10, :millisecond, :native)},
        %{
          model: "gpt-4o",
          provider: :openai,
          wire_protocol: :openai_chat,
          usage: %{
            input_tokens: 10,
            output_tokens: 20,
            input_cost: 0.0001,
            output_cost: 0.0004,
            total_cost: 0.0005,
            pricing: %{currency: "USD"}
          },
          finish_reason: :stop
        }
      )
    end)

    :ok = Recorder.flush_now()

    [row] = Repo.all(Call)
    assert row.project_key == "demo"
    assert row.session_id == "s1"
    assert row.feature == "step_summarization"
    assert row.model == "gpt-4o"
    assert row.total_cost == 0.0005
    assert row.currency == "USD"
  end
end
