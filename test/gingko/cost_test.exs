defmodule Gingko.CostTest do
  use Gingko.DataCase, async: false

  alias Gingko.Cost
  alias Gingko.Cost.Call
  alias Gingko.Repo

  setup do
    Repo.delete_all(Call)
    seed_rows()
    :ok
  end

  defp seed_rows do
    base = ~U[2026-05-01 12:00:00.000000Z]

    rows = [
      row(base, "demo", "gpt-4o", "step_summarization", 0.01, "USD"),
      row(DateTime.add(base, 1, :hour), "demo", "gpt-4o", "step_summarization", 0.02, "USD"),
      row(
        DateTime.add(base, 2, :hour),
        "demo",
        "claude-sonnet-4-6",
        "project_summary",
        0.05,
        "USD"
      ),
      row(DateTime.add(base, 3, :hour), "other", "gpt-4o", "mcp_structuring", 0.03, "USD"),
      row(DateTime.add(base, 4, :hour), "demo", "gpt-4o", "step_summarization", nil, nil),
      row(DateTime.add(base, 5, :hour), "demo", "gpt-4o", "step_summarization", 0.04, "EUR")
    ]

    Repo.insert_all(Call, rows)
  end

  defp row(at, project, model, feature, cost, currency) do
    %{
      id: Ecto.UUID.generate(),
      occurred_at: at,
      inserted_at: at,
      model: model,
      event_kind: "request",
      status: "ok",
      project_key: project,
      feature: feature,
      total_cost: cost,
      currency: currency,
      input_tokens: 100,
      output_tokens: 50
    }
  end

  test "totals/1 sums per currency and excludes unpriced rows" do
    t = Cost.totals()
    by_currency = Map.new(t.by_currency, &{&1.currency, &1.total_cost})

    assert_in_delta by_currency["USD"], 0.11, 1.0e-9
    assert_in_delta by_currency["EUR"], 0.04, 1.0e-9
    assert t.calls == 6
    assert t.unpriced_count == 1
  end

  test "totals/1 with filter narrows to one project" do
    t = Cost.totals(%{project_key: "demo"})
    assert t.calls == 5
  end

  test "breakdown_by feature returns per-currency rows ordered by cost desc" do
    rows = Cost.breakdown_by(%{}, :feature, limit: 5)

    assert length(rows) == 4
    assert hd(rows).key == "project_summary"
    assert hd(rows).currency == "USD"
    assert_in_delta hd(rows).total_cost, 0.05, 1.0e-9

    usd_rows = Enum.filter(rows, &(&1.currency == "USD"))
    usd_keys = Enum.map(usd_rows, & &1.key)
    assert "step_summarization" in usd_keys
    assert "project_summary" in usd_keys
    assert "mcp_structuring" in usd_keys

    eur_rows = Enum.filter(rows, &(&1.currency == "EUR"))
    assert length(eur_rows) == 1
    assert hd(eur_rows).key == "step_summarization"
    assert_in_delta hd(eur_rows).total_cost, 0.04, 1.0e-9
  end

  test "recent_calls returns rows newest-first" do
    rows = Cost.recent_calls()
    assert length(rows) == 6
    assert Enum.sort_by(rows, & &1.occurred_at, {:desc, DateTime}) == rows
  end

  test "time_series day buckets group by currency with correct sums" do
    rows = Cost.time_series(%{}, :day)

    assert length(rows) == 2
    assert Enum.all?(rows, fn r -> r.bucket_at == ~U[2026-05-01 00:00:00Z] end)

    usd = Enum.find(rows, &(&1.currency == "USD"))
    assert usd.calls == 4
    assert_in_delta usd.total_cost, 0.11, 1.0e-9

    eur = Enum.find(rows, &(&1.currency == "EUR"))
    assert eur.calls == 1
    assert_in_delta eur.total_cost, 0.04, 1.0e-9
  end
end
