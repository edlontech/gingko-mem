defmodule Gingko.Projects.Session do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active finished abandoned)

  schema "sessions" do
    field(:session_id, :string)
    field(:status, :string, default: "active")
    field(:goal, :string)
    field(:node_ids, {:array, :string}, default: [])
    field(:node_count, :integer, default: 0)
    field(:trajectory_count, :integer, default: 0)
    field(:started_at, :utc_datetime)
    field(:finished_at, :utc_datetime)

    belongs_to(:project, Gingko.Projects.Project)

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :project_id,
      :session_id,
      :status,
      :goal,
      :node_ids,
      :node_count,
      :trajectory_count,
      :started_at,
      :finished_at
    ])
    |> validate_required([:project_id, :session_id, :status, :started_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:session_id)
  end
end
