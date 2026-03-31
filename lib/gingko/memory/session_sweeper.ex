defmodule Gingko.Memory.SessionSweeper do
  @moduledoc """
  Periodic sweeper that cleans up stale sessions.

  Sessions can get stuck as "active" in the database when a close/commit
  fails or the client disconnects before completing the session lifecycle.
  This process periodically scans for sessions whose last activity exceeds
  a configurable threshold and resolves them.
  """

  use GenServer

  require Logger

  alias Gingko.Memory
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects

  @default_interval_ms :timer.minutes(2)
  @default_stale_after_ms :timer.minutes(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    stale_after = Keyword.get(opts, :stale_after_ms, @default_stale_after_ms)

    schedule_sweep(interval)

    {:ok, %{interval_ms: interval, stale_after_ms: stale_after}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.stale_after_ms)
    schedule_sweep(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end

  defp sweep(stale_after_ms) do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -stale_after_ms, :millisecond)

    Projects.list_stale_active_sessions(cutoff)
    |> Enum.each(&resolve_stale_session/1)
  rescue
    error ->
      Logger.debug("Session sweeper error: #{inspect(error)}")
      :ok
  end

  defp resolve_stale_session(session) do
    session_id = session.session_id
    project_key = session.project.project_key

    case Mnemosyne.session_state(session_id) do
      state when state in [:idle, :closed, :committed, :failed, :error, :terminated] ->
        Logger.info(
          "Sweeping stale session #{session_id} (state=#{state}) from project #{project_key}"
        )

        finish_and_broadcast(project_key, session_id)

      {:error, _} ->
        Logger.info("Sweeping orphaned session #{session_id} from project #{project_key}")
        finish_and_broadcast(project_key, session_id)

      :collecting ->
        try_close_stale(project_key, session_id)

      active_state ->
        Logger.debug(
          "Skipping stale session #{session_id} in state #{active_state}, waiting for completion"
        )
    end
  end

  defp try_close_stale(project_key, session_id) do
    Logger.info("Force-closing stale session #{session_id} in project #{project_key}")

    case Memory.close_async(%{session_id: session_id}) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        finish_and_broadcast(project_key, session_id)
    end
  rescue
    error ->
      Logger.warning("Failed to close session #{session_id}: #{Exception.message(error)}")

      finish_and_broadcast(project_key, session_id)
  end

  defp finish_and_broadcast(project_key, session_id) do
    Projects.finish_session(session_id)

    event = %SessionMonitorEvent{
      type: :session_expired,
      project_id: project_key,
      repo_id: project_key,
      timestamp: DateTime.utc_now(),
      session_id: session_id,
      summary: %{reason: :stale}
    }

    Phoenix.PubSub.broadcast(
      Gingko.PubSub,
      Memory.project_monitor_topic(project_key),
      {:memory_event, event}
    )
  rescue
    _ -> :ok
  end
end
