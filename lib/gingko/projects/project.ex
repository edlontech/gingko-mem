defmodule Gingko.Projects.Project do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field(:project_key, :string)
    field(:display_name, :string)

    field(:overlay_base, :string, default: "inherit_global")
    field(:overlay_domain_context, :string)
    field(:overlay_steps, :map, default: %{})
    field(:overlay_value_function_overrides, :map, default: %{})
    field(:overlay_updated_at, :utc_datetime)

    has_many(:memories, Gingko.Projects.ProjectMemory)

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:project_key, :display_name])
    |> validate_required([:project_key])
    |> unique_constraint(:project_key)
  end

  def changeset_overlay(project, attrs) do
    project
    |> cast(attrs, [
      :overlay_base,
      :overlay_domain_context,
      :overlay_steps,
      :overlay_value_function_overrides,
      :overlay_updated_at
    ])
    |> validate_required([:overlay_base])
  end
end
