defmodule Gingko.Cost.PrunerTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Cost.Pruner
  alias Gingko.Repo

  setup :set_mimic_global

  setup do
    Repo.delete_all(Call)
    :ok
  end

  defp insert_row(at) do
    Repo.insert_all(Call, [
      %{
        id: Ecto.UUID.generate(),
        occurred_at: at,
        inserted_at: at,
        model: "gpt-4o",
        event_kind: "request",
        status: "ok"
      }
    ])
  end

  test "retention_days = 0 leaves rows alone" do
    stub(Config, :retention_days, fn -> 0 end)

    insert_row(DateTime.add(DateTime.utc_now(), -120 * 86_400, :second))

    assert {:ok, %{deleted: 0}} = Pruner.perform(%Oban.Job{args: %{}})
    assert Repo.aggregate(Call, :count, :id) == 1
  end

  test "deletes rows older than cutoff and keeps recent rows" do
    stub(Config, :retention_days, fn -> 30 end)

    insert_row(DateTime.add(DateTime.utc_now(), -100 * 86_400, :second))
    insert_row(DateTime.add(DateTime.utc_now(), -1 * 86_400, :second))

    assert {:ok, %{deleted: 1}} = Pruner.perform(%Oban.Job{args: %{}})
    assert Repo.aggregate(Call, :count, :id) == 1
  end
end
