defmodule Gingko.Repo.Migrations.CreateProjectsAndProjectMemories do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :project_key, :string, null: false
      add :display_name, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:project_key])

    create table(:project_memories) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :branch_name, :string
      add :repo_id, :string, null: false
      add :dets_path, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_memories, [:repo_id])

    create unique_index(:project_memories, [:project_id, :kind],
             where: "kind = 'root'",
             name: :project_memories_unique_root_index
           )

    create unique_index(:project_memories, [:project_id, :branch_name],
             where: "kind = 'branch'",
             name: :project_memories_unique_branch_index
           )
  end
end
