defmodule Gingko.Repo.Migrations.InstallOban do
  use Ecto.Migration

  def up, do: Oban.Migration.up(engine: Oban.Engines.Lite)
  def down, do: Oban.Migration.down()
end
