defmodule Gingko.Cost.Recorder do
  @moduledoc """
  Batching writer for `Gingko.Cost.Call` rows.

  Receives rows via `record/1` (cast), buffers in memory, and flushes via
  `Repo.insert_all` on size, time, or mailbox-pressure triggers. Broadcasts
  flushed rows on `Gingko.PubSub` topic `"cost:rows"` for live consumers.
  """

  use GenServer

  require Logger

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Repo

  @topic "cost:rows"
  @mailbox_soft_cap 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Topic on which flushed rows are broadcast."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Cast a row map (already shaped like `Cost.Call` fields) for eventual insertion."
  @spec record(map()) :: :ok
  def record(row) when is_map(row) do
    GenServer.cast(__MODULE__, {:row, row})
  end

  @doc "Synchronous flush for tests and graceful shutdown coordination."
  @spec flush_now() :: :ok
  def flush_now, do: GenServer.call(__MODULE__, :flush_now)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{buffer: [], flush_timer: nil}}
  end

  @impl true
  def handle_cast({:row, row}, state) do
    state = %{state | buffer: [row | state.buffer]}

    cond do
      length(state.buffer) >= Config.batch_size_max() ->
        {:noreply, flush(state)}

      mailbox_overloaded?() ->
        Logger.warning("Cost.Recorder mailbox over soft cap, flushing")
        {:noreply, flush(state)}

      state.flush_timer == nil ->
        {:noreply, %{state | flush_timer: schedule_flush()}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(state)}

  @impl true
  def handle_call(:flush_now, _from, state), do: {:reply, :ok, flush(state)}

  @impl true
  def terminate(_reason, state) do
    _ = flush(state)
    :ok
  end

  defp flush(%{buffer: []} = state), do: cancel_timer(state)

  defp flush(%{buffer: buffer} = state) do
    rows = Enum.reverse(buffer)
    {_, _} = Repo.insert_all(Call, rows)
    Phoenix.PubSub.broadcast(Gingko.PubSub, @topic, {:cost_rows, rows})
    cancel_timer(%{state | buffer: []})
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, Config.flush_interval_ms())
  end

  defp cancel_timer(%{flush_timer: nil} = state), do: state

  defp cancel_timer(%{flush_timer: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | flush_timer: nil}
  end

  defp mailbox_overloaded? do
    case :erlang.process_info(self(), :message_queue_len) do
      {:message_queue_len, len} -> len > @mailbox_soft_cap
      _ -> false
    end
  end
end
