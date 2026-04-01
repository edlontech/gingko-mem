defmodule Gingko.NxBackend do
  @moduledoc false

  require Logger

  @spec configure(keyword()) :: :ok
  def configure(opts \\ []) do
    os_type = Keyword.get(opts, :os_type, &:os.type/0).()
    loaded? = Keyword.get(opts, :loaded?, &Code.ensure_loaded?/1)

    case os_type do
      {:unix, :linux} ->
        maybe_set_exla_backend(loaded?)

      {:unix, :darwin} ->
        maybe_set_emlx_backend(loaded?)

      _ ->
        :ok
    end
  end

  @doc """
  Returns a backend spec that runs on CPU, for ops not supported on GPU accelerators.
  Falls back to `Nx.BinaryBackend` when no accelerator is loaded.
  """
  @spec cpu_backend() :: module() | {module(), keyword()}
  def cpu_backend do
    cond do
      Code.ensure_loaded?(EMLX.Backend) -> {EMLX.Backend, device: :cpu}
      Code.ensure_loaded?(EXLA.Backend) -> {EXLA.Backend, client: :host}
      true -> Nx.BinaryBackend
    end
  end

  defp maybe_set_exla_backend(loaded?) do
    if loaded?.(EXLA.Backend) do
      Logger.info("Setting EXLA as the global default backend for Nx")
      Nx.global_default_backend(EXLA.Backend)
    end

    :ok
  end

  defp maybe_set_emlx_backend(loaded?) do
    if loaded?.(EMLX.Backend) and loaded?.(EMLX) do
      Logger.info("Setting EMLX as the global default backend for Nx with GPU support")
      Nx.global_default_backend({EMLX.Backend, device: :gpu})
    end

    :ok
  end
end
