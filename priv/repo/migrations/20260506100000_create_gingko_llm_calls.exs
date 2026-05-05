defmodule Gingko.Repo.Migrations.CreateGingkoLlmCalls do
  use Ecto.Migration

  def change do
    create table(:gingko_llm_calls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:duration_ms, :integer)

      add(:provider, :string)
      add(:model, :string, null: false)
      add(:wire_protocol, :string)
      add(:event_kind, :string, null: false)

      add(:status, :string, null: false)
      add(:finish_reason, :string)
      add(:error_class, :string)
      add(:response_id, :string)
      add(:response_model, :string)

      add(:input_tokens, :integer)
      add(:output_tokens, :integer)
      add(:cache_read_input_tokens, :integer)
      add(:cache_creation_input_tokens, :integer)
      add(:reasoning_tokens, :integer)

      add(:input_cost, :float)
      add(:output_cost, :float)
      add(:cache_read_cost, :float)
      add(:cache_write_cost, :float)
      add(:reasoning_cost, :float)
      add(:total_cost, :float)
      add(:currency, :string)

      add(:project_key, :string)
      add(:session_id, :string)
      add(:feature, :string)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:gingko_llm_calls, [:occurred_at]))
    create(index(:gingko_llm_calls, [:project_key, :occurred_at]))
    create(index(:gingko_llm_calls, [:feature, :occurred_at]))
    create(index(:gingko_llm_calls, [:model, :occurred_at]))
  end
end
