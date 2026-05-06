defmodule Gingko.Repo.Migrations.CreateProviderCredentials do
  use Ecto.Migration

  def change do
    create table(:provider_credentials) do
      add :provider, :string, null: false
      add :key, :string, null: false
      add :value, :text, null: false
      add :expires_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_credentials, [:provider, :key])
  end
end
