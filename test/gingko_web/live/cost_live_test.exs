defmodule GingkoWeb.CostLiveTest do
  use GingkoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Gingko.Cost.Call
  alias Gingko.Repo

  setup do
    Repo.delete_all(Call)
    :ok
  end

  defp seed(extra \\ %{}) do
    base = %{
      id: Ecto.UUID.generate(),
      occurred_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now(),
      model: "gpt-4o",
      event_kind: "request",
      status: "ok",
      project_key: "demo",
      feature: "step_summarization",
      total_cost: 0.10,
      currency: "USD",
      input_tokens: 10,
      output_tokens: 20
    }

    Repo.insert_all(Call, [Map.merge(base, extra)])
  end

  test "renders KPIs and breakdowns", %{conn: conn} do
    seed()
    {:ok, _view, html} = live(conn, "/cost")
    assert html =~ "USD"
    assert html =~ "demo"
    assert html =~ "step_summarization"
    assert html =~ "gpt-4o"
  end

  test "PubSub broadcast updates totals incrementally", %{conn: conn} do
    seed()
    {:ok, view, _} = live(conn, "/cost")

    new_row = %{
      id: Ecto.UUID.generate(),
      occurred_at: DateTime.utc_now(),
      inserted_at: DateTime.utc_now(),
      model: "gpt-4o",
      event_kind: "request",
      status: "ok",
      project_key: "demo",
      feature: "step_summarization",
      total_cost: 0.05,
      currency: "USD",
      input_tokens: 5,
      output_tokens: 5,
      cache_read_input_tokens: 3,
      duration_ms: nil,
      provider: nil,
      response_id: nil
    }

    send(view.pid, {:cost_rows, [new_row]})

    rendered = render(view)
    assert rendered =~ "0.1500"
    assert rendered =~ "2 calls"
    assert rendered =~ "3 cache"
  end

  test "empty state renders when no rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/cost")
    assert html =~ "No LLM calls recorded yet"
  end

  test "clear_filters removes active filters", %{conn: conn} do
    seed()
    seed(%{id: Ecto.UUID.generate(), project_key: "other", total_cost: 0.20})

    {:ok, view, html} = live(conn, "/cost?project_key=demo")
    assert html =~ "Clear filters"
    assert html =~ "project_key: demo"

    rendered = render_click(view, "clear_filters")
    refute rendered =~ "Clear filters"
    refute rendered =~ "project_key: demo"
    assert rendered =~ "other"
  end
end
