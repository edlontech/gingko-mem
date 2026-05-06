defmodule Gingko.Credentials.Credential do
  @moduledoc """
  Per-provider credential entry persisted in the local SQLite store.

  A credential is keyed by `(provider, key)`. The `value` holds the secret
  (e.g. a `gho_...` GitHub OAuth token); `expires_at` may be set when the
  upstream provider issues short-lived tokens. `metadata` carries non-secret
  side-channel data (token type, scopes, etc.).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "provider_credentials" do
    field(:provider, :string)
    field(:key, :string)
    field(:value, :string)
    field(:expires_at, :utc_datetime)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @required ~w(provider key value)a
  @optional ~w(expires_at metadata)a

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:provider, :key])
  end
end
