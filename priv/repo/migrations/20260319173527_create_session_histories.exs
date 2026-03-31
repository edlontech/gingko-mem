defmodule Gingko.Repo.Migrations.CreateSessionHistories do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add(:project_id, references(:projects, on_delete: :delete_all), null: false)
      add(:session_id, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:goal, :string)
      add(:node_ids, :string, null: false, default: "[]")
      add(:node_count, :integer, null: false, default: 0)
      add(:trajectory_count, :integer, null: false, default: 0)
      add(:started_at, :utc_datetime, null: false)
      add(:finished_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:sessions, [:session_id]))
    create(index(:sessions, [:project_id, :status]))
    create(index(:sessions, [:project_id, :started_at]))
  end
end
