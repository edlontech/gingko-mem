defmodule Gingko.Credentials.Runtime do
  @moduledoc """
  Boundary between Gingko credentials and Sycophant's app-env-driven config.

  Sycophant resolves provider credentials from `Application.get_env(:sycophant, :providers)`
  before falling back to environment variables. Gingko owns the credential
  store, so on boot and after every credential mutation we replay the full
  set into that app env entry.

  This module is the single point where the mutation happens, which lets
  tests stub it via Mimic instead of actually mutating application env.
  """

  @sycophant_app :sycophant

  @doc """
  Replaces the credential keyword list for `provider` under
  `:sycophant, :providers`. Other providers configured there are preserved.
  """
  @spec put_provider(atom(), keyword()) :: :ok
  def put_provider(provider, kwlist) when is_atom(provider) and is_list(kwlist) do
    current = Application.get_env(@sycophant_app, :providers, [])
    Application.put_env(@sycophant_app, :providers, Keyword.put(current, provider, kwlist))
  end

  @doc """
  Removes `provider` from `:sycophant, :providers`.
  """
  @spec delete_provider(atom()) :: :ok
  def delete_provider(provider) when is_atom(provider) do
    current = Application.get_env(@sycophant_app, :providers, [])
    Application.put_env(@sycophant_app, :providers, Keyword.delete(current, provider))
  end
end
