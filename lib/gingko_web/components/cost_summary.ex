defmodule GingkoWeb.CostSummary do
  @moduledoc "Embedded cost strip rendered inside ProjectLive."
  use Phoenix.Component

  alias Gingko.Cost

  attr :project_key, :string, required: true
  attr :class, :string, default: nil

  def strip(assigns) do
    rows = totals_for(assigns.project_key)

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div class={["flex items-center gap-3 text-sm", @class]}>
      <span class="font-semibold text-base-content/80">Cost</span>
      <span :for={{label, amount} <- @rows} class="tabular-nums">
        <span class="text-base-content/60">{label}:</span> {amount}
      </span>
      <.link
        navigate={"/cost?project_key=" <> URI.encode_www_form(@project_key)}
        class="link link-primary text-xs"
      >
        details →
      </.link>
    </div>
    """
  end

  defp totals_for(project_key) do
    now = DateTime.utc_now()

    [
      {"24h", DateTime.add(now, -86_400, :second)},
      {"7d", DateTime.add(now, -7 * 86_400, :second)},
      {"30d", DateTime.add(now, -30 * 86_400, :second)}
    ]
    |> Enum.map(fn {label, from} ->
      totals = Cost.totals(%{project_key: project_key, from: from})
      {label, format_amount(totals.by_currency)}
    end)
  end

  defp format_amount([]), do: "—"

  defp format_amount([%{total_cost: cost, currency: curr}]) do
    "#{curr} #{:erlang.float_to_binary(cost * 1.0, decimals: 4)}"
  end

  defp format_amount(_multi), do: "—"
end
