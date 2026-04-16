defmodule Gingko.Summaries.PrincipalMemorySection do
  @moduledoc """
  Schema for tier-0 principal memory sections (playbook, charter, state).

  One row per (project_key, kind). `locked=true` rows are skipped by the
  regeneration workers so users can pin content manually.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(playbook charter state)

  @type t :: %__MODULE__{}

  schema "principal_memory_sections" do
    field(:project_key, :string)
    field(:kind, :string)
    field(:content, :string, default: "")
    field(:frontmatter, :map, default: %{})
    field(:locked, :boolean, default: false)

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of allowed `kind` values."
  def kinds, do: @kinds

  def changeset(section, attrs) do
    section
    |> cast(attrs, [:project_key, :kind, :content, :frontmatter, :locked])
    |> validate_required([:project_key, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:project_key, :kind])
  end
end
