defmodule Gingko.Summaries.ClusterSummary do
  @moduledoc """
  Schema for tier-1 cluster summaries, keyed by (project_key, tag_node_id).

  `memory_refs` is stored as a wrapper map `%{"refs" => [...]}` because the
  `ecto_sqlite3` `:map` type only serializes maps, not bare lists.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "cluster_summaries" do
    field(:project_key, :string)
    field(:tag_node_id, :string)
    field(:tag_label, :string)
    field(:slug, :string)
    field(:headline, :string)
    field(:content, :string, default: "")
    field(:memory_count, :integer, default: 0)
    field(:memory_refs, :map, default: %{"refs" => []})
    field(:frontmatter, :map, default: %{})
    field(:dirty, :boolean, default: true)
    field(:dirty_since, :utc_datetime)
    field(:last_generated_at, :utc_datetime)
    field(:regen_count, :integer, default: 0)
    field(:locked, :boolean, default: false)

    timestamps(type: :utc_datetime)
  end

  def changeset(cluster, attrs) do
    cluster
    |> cast(attrs, [
      :project_key,
      :tag_node_id,
      :tag_label,
      :slug,
      :headline,
      :content,
      :memory_count,
      :memory_refs,
      :frontmatter,
      :dirty,
      :dirty_since,
      :last_generated_at,
      :regen_count,
      :locked
    ])
    |> validate_required([:project_key, :tag_node_id, :tag_label, :slug])
    |> unique_constraint([:project_key, :tag_node_id])
  end
end
