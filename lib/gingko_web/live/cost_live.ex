defmodule GingkoWeb.CostLive do
  @moduledoc """
  Read-only dashboard at `/cost` summarizing LLM cost over a configurable
  time range, with breakdowns by project, feature, and model and a live
  recent-calls table.
  """

  use GingkoWeb, :live_view

  alias Gingko.Cost
  alias Gingko.Cost.Recorder

  @ranges %{
    "24h" => 86_400,
    "7d" => 7 * 86_400,
    "30d" => 30 * 86_400
  }

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Gingko.PubSub, Recorder.topic())
    end

    filters =
      params
      |> Map.take(~w(project_key feature model status))
      |> Enum.reject(fn {_, v} -> v in ["", nil] end)
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

    {:ok,
     socket
     |> assign(:range, "7d")
     |> assign(:filters, filters)
     |> load_data()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) when is_map_key(@ranges, range) do
    {:noreply, socket |> assign(:range, range) |> load_data()}
  end

  def handle_event("filter", params, socket) do
    new_filters =
      params
      |> Map.take(~w(project_key feature model status))
      |> Enum.reject(fn {_, v} -> v in ["", nil] end)
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

    merged = Map.merge(socket.assigns.filters, new_filters)
    {:noreply, socket |> assign(:filters, merged) |> load_data()}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(:filters, %{}) |> load_data()}
  end

  @impl true
  def handle_info({:cost_rows, rows}, socket) do
    matching = Enum.filter(rows, &row_matches?(&1, socket.assigns))

    if matching == [] do
      {:noreply, socket}
    else
      {:noreply, apply_incremental(socket, matching)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp row_matches?(row, %{filters: filters, range: range}) do
    seconds = Map.fetch!(@ranges, range)
    from = DateTime.add(DateTime.utc_now(), -seconds, :second)

    in_range? =
      case Map.get(row, :occurred_at) do
        %DateTime{} = dt -> DateTime.compare(dt, from) != :lt
        _ -> true
      end

    in_range? and
      Enum.all?(filters, fn
        {:project_key, v} -> Map.get(row, :project_key) == v
        {:feature, v} -> Map.get(row, :feature) == v
        {:model, v} -> Map.get(row, :model) == v
        {:status, v} -> Map.get(row, :status) == v
      end)
  end

  defp apply_incremental(socket, rows) do
    socket
    |> update(:recent, fn existing -> Enum.take(rows ++ existing, 50) end)
    |> update(:totals, fn t -> add_to_totals(t, rows) end)
  end

  defp add_to_totals(t, rows) do
    delta_calls = length(rows)
    delta_unpriced = Enum.count(rows, &is_nil(Map.get(&1, :total_cost)))
    delta_input = Enum.reduce(rows, 0, fn r, acc -> acc + (Map.get(r, :input_tokens) || 0) end)
    delta_output = Enum.reduce(rows, 0, fn r, acc -> acc + (Map.get(r, :output_tokens) || 0) end)

    delta_cache =
      Enum.reduce(rows, 0, fn r, acc -> acc + (Map.get(r, :cache_read_input_tokens) || 0) end)

    delta_ok = Enum.count(rows, &(Map.get(&1, :status) == "ok"))
    delta_error = Enum.count(rows, &(Map.get(&1, :status) == "error"))

    %{
      t
      | by_currency: merge_currency_costs(t.by_currency, rows),
        calls: t.calls + delta_calls,
        unpriced_count: t.unpriced_count + delta_unpriced,
        ok_count: t.ok_count + delta_ok,
        error_count: t.error_count + delta_error,
        input_tokens: t.input_tokens + delta_input,
        output_tokens: t.output_tokens + delta_output,
        cache_tokens: t.cache_tokens + delta_cache
    }
  end

  defp merge_currency_costs(existing, new_rows) do
    deltas =
      Enum.reduce(new_rows, %{}, fn r, acc ->
        cost = Map.get(r, :total_cost)
        currency = Map.get(r, :currency)

        if cost && currency,
          do: Map.update(acc, currency, cost, &(&1 + cost)),
          else: acc
      end)

    Enum.reduce(deltas, existing, fn {curr, delta}, acc ->
      case Enum.split_with(acc, &(&1.currency == curr)) do
        {[], rest} ->
          [%{currency: curr, total_cost: delta, calls: 0} | rest]

        {[hit | _], rest} ->
          [%{hit | total_cost: hit.total_cost + delta} | rest]
      end
    end)
  end

  defp load_data(socket) do
    filter = build_filter(socket.assigns.range, socket.assigns.filters)

    socket
    |> assign(:totals, Cost.totals(filter))
    |> assign(:by_project, Cost.breakdown_by(filter, :project_key))
    |> assign(:by_feature, Cost.breakdown_by(filter, :feature))
    |> assign(:by_model, Cost.breakdown_by(filter, :model))
    |> assign(:recent, Cost.recent_calls(filter))
  end

  defp build_filter(range, filters) do
    seconds = Map.fetch!(@ranges, range)
    from = DateTime.add(DateTime.utc_now(), -seconds, :second)
    Map.merge(%{from: from}, filters)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title="Cost"
      update_status={@update_status}
      update_apply={@update_apply}
      update_supervised={@update_supervised}
    >
      <section class="mx-auto w-full max-w-[112rem] px-4 py-6 sm:px-6 lg:px-8">
        <.header>
          Cost
          <:subtitle>{@totals.calls} calls · {@totals.unpriced_count} unpriced</:subtitle>
        </.header>

        <div class="mt-4 flex flex-wrap items-center gap-2">
          <div class="join">
            <button
              :for={r <- ~w(24h 7d 30d)}
              phx-click="set_range"
              phx-value-range={r}
              class={["btn btn-sm join-item", if(@range == r, do: "btn-primary", else: "")]}
            >
              {r}
            </button>
          </div>

          <button
            :if={map_size(@filters) > 0}
            phx-click="clear_filters"
            class="btn btn-sm btn-ghost"
          >
            Clear filters
          </button>

          <span :for={{k, v} <- @filters} class="badge badge-outline gap-1">
            {k}: {v}
          </span>
        </div>

        <div class="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <div
            :for={c <- @totals.by_currency}
            class="rounded-2xl border border-base-300 bg-base-100 p-4"
          >
            <p class="text-xs uppercase text-base-content/60">Total {c.currency}</p>
            <p class="mt-1 text-2xl tabular-nums">{format_cost(c.total_cost)}</p>
            <p class="text-xs text-base-content/60">{c.calls} priced calls</p>
          </div>

          <div
            :if={@totals.by_currency == []}
            class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-4 text-sm text-base-content/70"
          >
            No priced calls in window.
          </div>

          <div class="rounded-2xl border border-base-300 bg-base-100 p-4">
            <p class="text-xs uppercase text-base-content/60">Calls</p>
            <p class="mt-1 text-2xl tabular-nums">{@totals.calls}</p>
            <p class="text-xs text-base-content/60">
              {@totals.ok_count} ok · {@totals.error_count} err
            </p>
          </div>

          <div class="rounded-2xl border border-base-300 bg-base-100 p-4">
            <p class="text-xs uppercase text-base-content/60">Tokens</p>
            <p class="mt-1 text-2xl tabular-nums">
              {@totals.input_tokens + @totals.output_tokens}
            </p>
            <p class="text-xs text-base-content/60">
              {@totals.input_tokens} in / {@totals.output_tokens} out / {@totals.cache_tokens} cache
            </p>
          </div>
        </div>

        <div class="mt-6 grid gap-4 lg:grid-cols-3">
          <.breakdown
            title="By project"
            rows={@by_project}
            dimension="project_key"
            filters={@filters}
          />
          <.breakdown title="By feature" rows={@by_feature} dimension="feature" filters={@filters} />
          <.breakdown title="By model" rows={@by_model} dimension="model" filters={@filters} />
        </div>

        <div class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-4">
          <h3 class="text-sm font-semibold">Recent calls</h3>

          <div :if={@recent == []} class="mt-3 text-sm text-base-content/70">
            No LLM calls recorded yet.
          </div>

          <div :if={@recent != []} class="mt-3 overflow-x-auto">
            <table class="table table-zebra table-xs">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Project</th>
                  <th>Session</th>
                  <th>Feature</th>
                  <th>Model</th>
                  <th>Status</th>
                  <th class="text-right">In/Out</th>
                  <th class="text-right">Cost</th>
                  <th class="text-right">ms</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- @recent}>
                  <td class="font-mono text-xs">{format_when(Map.get(r, :occurred_at))}</td>
                  <td>{Map.get(r, :project_key) || "—"}</td>
                  <td class="font-mono text-xs">{shorten(Map.get(r, :session_id))}</td>
                  <td>{Map.get(r, :feature) || "—"}</td>
                  <td class="font-mono text-xs">{Map.get(r, :model)}</td>
                  <td>
                    <span class={["badge badge-xs", status_badge(Map.get(r, :status))]}>
                      {Map.get(r, :status)}
                    </span>
                  </td>
                  <td class="text-right tabular-nums">
                    {Map.get(r, :input_tokens) || 0}/{Map.get(r, :output_tokens) || 0}
                  </td>
                  <td class="text-right tabular-nums">
                    {format_row_cost(Map.get(r, :total_cost), Map.get(r, :currency))}
                  </td>
                  <td class="text-right tabular-nums">{Map.get(r, :duration_ms) || "—"}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :dimension, :string, required: true
  attr :filters, :map, required: true

  defp breakdown(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-4">
      <h3 class="text-sm font-semibold">{@title}</h3>

      <div :if={@rows == []} class="mt-3 text-sm text-base-content/70">No data.</div>

      <ul :if={@rows != []} class="mt-3 space-y-1 text-sm">
        <li :for={row <- @rows} class="flex items-center justify-between gap-3">
          <button
            phx-click="filter"
            phx-value-project_key={if @dimension == "project_key", do: row.key}
            phx-value-feature={if @dimension == "feature", do: row.key}
            phx-value-model={if @dimension == "model", do: row.key}
            class="truncate text-left hover:underline"
          >
            {row.key || "—"}
          </button>
          <span class="tabular-nums text-base-content/70">
            {row.currency} {format_cost(row.total_cost)} · {row.calls}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp format_cost(amount) when is_number(amount),
    do: :erlang.float_to_binary(amount * 1.0, decimals: 4)

  defp format_cost(_), do: "—"

  defp format_row_cost(nil, _), do: "—"

  defp format_row_cost(amount, currency) when is_number(amount),
    do: "#{currency} #{format_cost(amount)}"

  defp format_when(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_when(_), do: "—"

  defp shorten(nil), do: ""
  defp shorten(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp shorten(_), do: ""

  defp status_badge("ok"), do: "badge-success"
  defp status_badge("error"), do: "badge-error"
  defp status_badge(_), do: ""
end
