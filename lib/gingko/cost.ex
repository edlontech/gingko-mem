defmodule Gingko.Cost do
  @moduledoc """
  Read-side query API for the LLM cost tracker. All cost aggregations group
  by currency; rows with `total_cost = nil` are counted as "unpriced" and
  excluded from cost sums.
  """

  import Ecto.Query

  alias Gingko.Cost.Call
  alias Gingko.Repo

  @type filter :: %{
          optional(:from) => DateTime.t(),
          optional(:to) => DateTime.t(),
          optional(:project_key) => String.t() | [String.t()],
          optional(:feature) => String.t() | [String.t()],
          optional(:model) => String.t() | [String.t()],
          optional(:status) => String.t()
        }

  @spec totals(filter()) :: %{
          by_currency: [%{currency: String.t() | nil, total_cost: float, calls: integer}],
          calls: integer,
          unpriced_count: integer,
          ok_count: integer,
          error_count: integer,
          input_tokens: integer,
          output_tokens: integer,
          cache_tokens: integer
        }
  def totals(filter \\ %{}) do
    base = apply_filter(from(c in Call), filter)

    by_currency =
      base
      |> where([c], not is_nil(c.total_cost))
      |> group_by([c], c.currency)
      |> select([c], %{
        currency: c.currency,
        total_cost: sum(c.total_cost),
        calls: count(c.id)
      })
      |> Repo.all()

    aggregates =
      base
      |> select([c], %{
        calls: count(c.id),
        unpriced: sum(fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", c.total_cost)),
        ok: sum(fragment("CASE WHEN ? = 'ok' THEN 1 ELSE 0 END", c.status)),
        errors: sum(fragment("CASE WHEN ? = 'error' THEN 1 ELSE 0 END", c.status)),
        input: sum(c.input_tokens),
        output: sum(c.output_tokens),
        cache: sum(coalesce(c.cache_read_input_tokens, 0))
      })
      |> Repo.one()

    %{
      by_currency: by_currency,
      calls: aggregates.calls,
      unpriced_count: aggregates.unpriced || 0,
      ok_count: aggregates.ok || 0,
      error_count: aggregates.errors || 0,
      input_tokens: aggregates.input || 0,
      output_tokens: aggregates.output || 0,
      cache_tokens: aggregates.cache || 0
    }
  end

  @spec breakdown_by(filter(), :project_key | :feature | :model, keyword()) ::
          [
            %{
              key: String.t() | nil,
              total_cost: float,
              calls: integer,
              currency: String.t() | nil
            }
          ]
  def breakdown_by(filter \\ %{}, dimension, opts \\ [])
      when dimension in [:project_key, :feature, :model] do
    limit = Keyword.get(opts, :limit, 10)

    from(c in Call)
    |> apply_filter(filter)
    |> where([c], not is_nil(c.total_cost))
    |> group_by([c], [field(c, ^dimension), c.currency])
    |> select([c], %{
      key: field(c, ^dimension),
      currency: c.currency,
      total_cost: sum(c.total_cost),
      calls: count(c.id)
    })
    |> order_by([c], desc: sum(c.total_cost))
    |> limit(^limit)
    |> Repo.all()
  end

  @spec recent_calls(filter(), keyword()) :: [Call.t()]
  def recent_calls(filter \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(c in Call)
    |> apply_filter(filter)
    |> order_by(desc: :occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec time_series(filter(), :hour | :day) ::
          [
            %{
              bucket_at: DateTime.t(),
              currency: String.t() | nil,
              total_cost: float,
              calls: integer
            }
          ]
  def time_series(filter \\ %{}, bucket) when bucket in [:hour, :day] do
    bucket_format =
      case bucket do
        :hour -> "%Y-%m-%dT%H:00:00Z"
        :day -> "%Y-%m-%dT00:00:00Z"
      end

    from(c in Call)
    |> apply_filter(filter)
    |> where([c], not is_nil(c.total_cost))
    |> group_by([c], [fragment("strftime(?, ?)", ^bucket_format, c.occurred_at), c.currency])
    |> select([c], %{
      bucket_at:
        selected_as(fragment("strftime(?, ?)", ^bucket_format, c.occurred_at), :bucket_at),
      currency: c.currency,
      total_cost: sum(c.total_cost),
      calls: count(c.id)
    })
    |> order_by([c], asc: selected_as(:bucket_at))
    |> Repo.all()
    |> Enum.map(&parse_bucket/1)
  end

  defp parse_bucket(%{bucket_at: bucket} = row) do
    {:ok, dt, _} = DateTime.from_iso8601(bucket)
    %{row | bucket_at: dt}
  end

  defp apply_filter(query, filter) do
    Enum.reduce(filter, query, fn
      {:from, %DateTime{} = from}, q -> from(c in q, where: c.occurred_at >= ^from)
      {:to, %DateTime{} = to}, q -> from(c in q, where: c.occurred_at < ^to)
      {:project_key, v}, q -> filter_in(q, :project_key, v)
      {:feature, v}, q -> filter_in(q, :feature, v)
      {:model, v}, q -> filter_in(q, :model, v)
      {:status, v}, q -> from(c in q, where: c.status == ^v)
      _, q -> q
    end)
  end

  defp filter_in(q, field, values) when is_list(values),
    do: from(c in q, where: field(c, ^field) in ^values)

  defp filter_in(q, field, value),
    do: from(c in q, where: field(c, ^field) == ^value)
end
