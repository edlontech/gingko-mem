defmodule Gingko.Summaries.ClusterMembershipDelta do
  @moduledoc """
  Append-only event log of `(tag, memory)` pairs observed since the last
  cluster regeneration. Rows are truncated by `ClusterWorker` once their
  memories have been consumed into a summary.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "cluster_membership_deltas" do
    field(:project_key, :string)
    field(:tag_node_id, :string)
    field(:memory_node_id, :string)
    field(:observed_at, :utc_datetime)
  end

  def changeset(delta, attrs) do
    delta
    |> cast(attrs, [:project_key, :tag_node_id, :memory_node_id, :observed_at])
    |> validate_required([:project_key, :tag_node_id, :memory_node_id, :observed_at])
  end
end
