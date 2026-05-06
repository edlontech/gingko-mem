defmodule Gingko.Credentials do
  @moduledoc """
  Persists provider credentials in SQLite and projects them into Sycophant's
  runtime config.

  A credential is `(provider, key) -> value`. For GitHub Copilot the only
  required key is `github_token` (the `gho_...` OAuth token from the device
  flow); Sycophant exchanges that for a short-lived Copilot session token
  on its own.

  Use `sync_runtime/0` after boot or after credentials change so Sycophant
  can pick the new values up without an env-var redeploy.
  """

  import Ecto.Query

  alias Gingko.Credentials.Credential
  alias Gingko.Credentials.Runtime
  alias Gingko.Repo

  @typedoc "Provider name as understood by both Sycophant and LLMDB."
  @type provider :: atom()

  @doc """
  Returns the credential value for `(provider, key)`, or `nil`.
  """
  @spec get(provider(), String.t() | atom()) :: String.t() | nil
  def get(provider, key) do
    provider_str = to_string(provider)
    key_str = to_string(key)

    Repo.one(
      from(c in Credential,
        where: c.provider == ^provider_str and c.key == ^key_str,
        select: c.value
      )
    )
  end

  @doc """
  Lists all credentials for `provider` as a keyword list (atom keys, string values).
  """
  @spec list(provider()) :: keyword()
  def list(provider) do
    provider_str = to_string(provider)

    Credential
    |> where(provider: ^provider_str)
    |> Repo.all()
    |> Enum.map(fn %Credential{key: k, value: v} -> {String.to_atom(k), v} end)
  end

  @doc """
  Inserts or updates a credential. `attrs` may include `:expires_at` and `:metadata`.
  Triggers a Sycophant runtime sync on success.
  """
  @spec put(provider(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, Credential.t()} | {:error, Ecto.Changeset.t()}
  def put(provider, key, value, attrs \\ []) when is_binary(value) do
    provider_str = to_string(provider)
    key_str = to_string(key)

    base = %{
      provider: provider_str,
      key: key_str,
      value: value,
      expires_at: Keyword.get(attrs, :expires_at),
      metadata: Keyword.get(attrs, :metadata, %{})
    }

    existing =
      Repo.one(
        from(c in Credential,
          where: c.provider == ^provider_str and c.key == ^key_str
        )
      )

    changeset = Credential.changeset(existing || %Credential{}, base)

    with {:ok, credential} <- Repo.insert_or_update(changeset) do
      sync_provider(provider)
      {:ok, credential}
    end
  end

  @doc """
  Deletes all credentials for `provider`.
  """
  @spec delete_all(provider()) :: :ok
  def delete_all(provider) do
    provider_str = to_string(provider)

    Credential
    |> where(provider: ^provider_str)
    |> Repo.delete_all()

    Runtime.delete_provider(normalize_provider(provider))
    :ok
  end

  @doc """
  Replays every stored credential into Sycophant's app config. Safe to call
  repeatedly; idempotent.
  """
  @spec sync_runtime() :: :ok
  def sync_runtime do
    Credential
    |> Repo.all()
    |> Enum.group_by(& &1.provider)
    |> Enum.each(fn {provider_str, entries} ->
      kwlist = Enum.map(entries, fn %Credential{key: k, value: v} -> {String.to_atom(k), v} end)
      Runtime.put_provider(normalize_provider(provider_str), kwlist)
    end)

    :ok
  end

  defp sync_provider(provider) do
    kwlist = list(provider)
    Runtime.put_provider(normalize_provider(provider), kwlist)
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider(provider) when is_binary(provider), do: String.to_atom(provider)
end
