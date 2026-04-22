defmodule Gingko.Repo.Migrations.AddExtractionOverlayToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :overlay_base, :string, null: false, default: "inherit_global"
      add :overlay_domain_context, :text
      add :overlay_steps, :map, null: false, default: %{}
      add :overlay_value_function_overrides, :map, null: false, default: %{}
      add :overlay_updated_at, :utc_datetime
    end
  end
end
