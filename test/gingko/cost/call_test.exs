defmodule Gingko.Cost.CallTest do
  use ExUnit.Case, async: true

  alias Gingko.Cost.Call

  defp valid_attrs(extra \\ %{}) do
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

  test "accepts a row with full costs" do
    cs =
      Call.changeset(
        valid_attrs(%{
          input_tokens: 100,
          output_tokens: 250,
          input_cost: 0.0005,
          output_cost: 0.0125,
          total_cost: 0.013,
          currency: "USD",
          project_key: "demo",
          feature: "step_summarization"
        })
      )

    assert cs.valid?
  end

  test "accepts a row with all cost fields nil" do
    cs = Call.changeset(valid_attrs())
    assert cs.valid?
  end

  test "rejects unknown event_kind" do
    cs = Call.changeset(valid_attrs(%{event_kind: "bogus"}))
    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:event_kind]
  end

  test "rejects unknown status" do
    cs = Call.changeset(valid_attrs(%{status: "maybe"}))
    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:status]
  end

  test "accepts event_kind: embedding" do
    cs = Call.changeset(valid_attrs(%{event_kind: "embedding"}))
    assert cs.valid?
  end

  test "requires model" do
    cs = Call.changeset(Map.delete(valid_attrs(), :model))
    refute cs.valid?
    assert {"can't be blank", _} = cs.errors[:model]
  end
end
