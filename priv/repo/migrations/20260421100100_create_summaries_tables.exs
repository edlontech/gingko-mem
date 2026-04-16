defmodule Gingko.Repo.Migrations.CreateSummariesTables do
  use Ecto.Migration

  def change do
    create table(:principal_memory_sections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_key, :string, null: false)
      add(:kind, :string, null: false)
      add(:content, :text, null: false, default: "")
      add(:frontmatter, :map, null: false, default: %{})
      add(:locked, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:principal_memory_sections, [:project_key, :kind]))

    create table(:cluster_summaries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_key, :string, null: false)
      add(:tag_node_id, :string, null: false)
      add(:tag_label, :string, null: false)
      add(:slug, :string, null: false)
      add(:headline, :string)
      add(:content, :text, null: false, default: "")
      add(:memory_count, :integer, null: false, default: 0)
      add(:memory_refs, :map, null: false, default: %{"refs" => []})
      add(:frontmatter, :map, null: false, default: %{})
      add(:dirty, :boolean, null: false, default: true)
      add(:dirty_since, :utc_datetime)
      add(:last_generated_at, :utc_datetime)
      add(:regen_count, :integer, null: false, default: 0)
      add(:locked, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:cluster_summaries, [:project_key, :tag_node_id]))
    create(index(:cluster_summaries, [:project_key, :dirty]))

    create table(:cluster_membership_deltas, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_key, :string, null: false)
      add(:tag_node_id, :string, null: false)
      add(:memory_node_id, :string, null: false)
      add(:observed_at, :utc_datetime, null: false)
    end

    create(index(:cluster_membership_deltas, [:project_key, :tag_node_id, :observed_at]))
  end
end
