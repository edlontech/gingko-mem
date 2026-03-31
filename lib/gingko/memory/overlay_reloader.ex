defmodule Gingko.Memory.OverlayReloader do
  @moduledoc """
  Listens for per-project extraction-overlay changes and triggers a
  close+reopen of the affected project's Mnemosyne repo so the new
  configuration takes effect.

  Runtime reason: MemoryStore caches `Mnemosyne.Config` at repo open time;
  changing the overlay on disk is insufficient. This process owns the
  async reaction so LiveView save handlers stay fast.
  """

  use GenServer

  require Logger

  alias Gingko.Memory
  alias Gingko.Projects

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(:ok) do
    :ok = Projects.subscribe_overlays()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:overlay_updated, project_key}, state) when is_binary(project_key) do
    case Memory.reload_project_config(project_key) do
      {:ok, _} ->
        Logger.debug("reloaded project config for #{project_key}")

      {:error, reason} ->
        Logger.warning("failed to reload project config for #{project_key}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
