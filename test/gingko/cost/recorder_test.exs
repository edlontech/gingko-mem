defmodule Gingko.Cost.RecorderTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Cost.Recorder

  setup :set_mimic_global

  setup do
    stub(Config, :batch_size_max, fn -> 3 end)
    stub(Config, :flush_interval_ms, fn -> 50 end)

    Repo.delete_all(Call)
    Phoenix.PubSub.subscribe(Gingko.PubSub, Recorder.topic())

    {:ok, pid} = start_supervised({Recorder, name: Recorder})

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(Gingko.PubSub, Recorder.topic())
    end)

    %{pid: pid}
  end

  defp row(extra \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        occurred_at: DateTime.utc_now(),
        model: "gpt-4o",
        event_kind: "request",
        status: "ok",
        inserted_at: DateTime.utc_now()
      },
      extra
    )
  end

  test "batch trigger flushes immediately and broadcasts" do
    Recorder.record(row())
    Recorder.record(row())
    Recorder.record(row())

    assert_receive {:cost_rows, rows} when length(rows) == 3, 500
    assert Repo.aggregate(Call, :count, :id) == 3
  end

  test "time trigger flushes a single row" do
    Recorder.record(row())
    assert_receive {:cost_rows, [_]}, 500
    assert Repo.aggregate(Call, :count, :id) == 1
  end

  test "flush_now drains the buffer synchronously" do
    Recorder.record(row())
    :ok = Recorder.flush_now()
    assert Repo.aggregate(Call, :count, :id) == 1
  end

  test "terminate flushes outstanding rows", %{pid: pid} do
    Recorder.record(row())
    :ok = stop_supervised(Recorder)
    refute Process.alive?(pid)
    assert Repo.aggregate(Call, :count, :id) == 1
  end
end
