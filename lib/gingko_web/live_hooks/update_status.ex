defmodule GingkoWeb.LiveHooks.UpdateStatus do
  @moduledoc """
  Subscribes connected LiveViews to update-checker and update-applier
  broadcasts. Exposes two assigns:

    * `:update_status` — result of `Gingko.UpdateChecker.status/0`.
    * `:update_apply`  — current applier stage, one of
       `:idle | :starting | :downloading | :swapping | :restarting |
        {:done, version} | {:error, reason}`.

  Also wires the `gingko:start_update` event so any LiveView in the app
  can trigger an in-place upgrade from the topbar badge.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Gingko.UpdateApplier
  alias Gingko.UpdateChecker
  alias Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Gingko.PubSub, UpdateChecker.topic())
      Phoenix.PubSub.subscribe(Gingko.PubSub, UpdateApplier.topic())
    end

    socket =
      socket
      |> assign(:update_status, UpdateChecker.status())
      |> assign(:update_apply, :idle)
      |> assign(:update_supervised, UpdateApplier.restart_supervised?())
      |> LiveView.attach_hook(:gingko_update_status, :handle_info, &handle_message/2)
      |> LiveView.attach_hook(:gingko_update_event, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_message({:update_status, status}, socket) do
    {:halt, assign(socket, :update_status, status)}
  end

  defp handle_message({:apply_progress, stage}, socket) do
    {:halt, assign(socket, :update_apply, stage)}
  end

  defp handle_message(_, socket), do: {:cont, socket}

  defp handle_event("gingko:start_update", _params, socket) do
    case socket.assigns.update_apply do
      stage when stage in [:starting, :downloading, :swapping, :restarting] ->
        {:halt, socket}

      _ ->
        case UpdateApplier.start_async() do
          {:ok, _pid} -> {:halt, assign(socket, :update_apply, :starting)}
          _error -> {:halt, assign(socket, :update_apply, {:error, :spawn_failed})}
        end
    end
  end

  defp handle_event("gingko:check_updates", _params, socket) do
    UpdateChecker.check_now()
    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
