defmodule Gingko.Cost.Call do
  @moduledoc """
  One LLM request or embedding call. Append-only; rows are written by `Gingko.Cost.Recorder` and queried via `Gingko.Cost`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  @event_kinds ~w(request embedding)
  @statuses ~w(ok error)

  @fields ~w(
    id occurred_at duration_ms
    provider model wire_protocol event_kind
    status finish_reason error_class response_id response_model
    input_tokens output_tokens cache_read_input_tokens
    cache_creation_input_tokens reasoning_tokens
    input_cost output_cost cache_read_cost cache_write_cost
    reasoning_cost total_cost currency
    project_key session_id feature
    inserted_at
  )a

  @required ~w(id occurred_at model event_kind status inserted_at)a

  schema "gingko_llm_calls" do
    field(:occurred_at, :utc_datetime_usec)
    field(:duration_ms, :integer)

    field(:provider, :string)
    field(:model, :string)
    field(:wire_protocol, :string)
    field(:event_kind, :string)

    field(:status, :string)
    field(:finish_reason, :string)
    field(:error_class, :string)
    field(:response_id, :string)
    field(:response_model, :string)

    field(:input_tokens, :integer)
    field(:output_tokens, :integer)
    field(:cache_read_input_tokens, :integer)
    field(:cache_creation_input_tokens, :integer)
    field(:reasoning_tokens, :integer)

    field(:input_cost, :float)
    field(:output_cost, :float)
    field(:cache_read_cost, :float)
    field(:cache_write_cost, :float)
    field(:reasoning_cost, :float)
    field(:total_cost, :float)
    field(:currency, :string)

    field(:project_key, :string)
    field(:session_id, :string)
    field(:feature, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(call \\ %__MODULE__{}, attrs) do
    call
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_inclusion(:event_kind, @event_kinds)
    |> validate_inclusion(:status, @statuses)
  end
end
