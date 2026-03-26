defmodule Gingko.Projects.ProjectMemory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "project_memories" do
    field(:kind, Ecto.Enum, values: [:root, :branch])
    field(:branch_name, :string)
    field(:repo_id, :string)
    field(:dets_path, :string)

    belongs_to(:project, Gingko.Projects.Project)

    timestamps(type: :utc_datetime)
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:kind, :branch_name, :repo_id, :dets_path, :project_id])
    |> validate_required([:kind, :repo_id, :dets_path, :project_id])
    |> validate_branch_name()
    |> unique_constraint(:repo_id)
    |> unique_constraint(:kind, name: :project_memories_project_id_kind_index)
    |> unique_constraint(:branch_name, name: :project_memories_project_id_branch_name_index)
    |> foreign_key_constraint(:project_id)
  end

  defp validate_branch_name(changeset) do
    case get_field(changeset, :kind) do
      :root -> put_change(changeset, :branch_name, nil)
      :branch -> validate_required(changeset, [:branch_name])
      _ -> changeset
    end
  end
end
