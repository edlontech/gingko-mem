defmodule Gingko.Memory.ActivityStore do
  @moduledoc """
  ETS-backed ring buffer for recent notifier events per project.

  The GenServer exists solely to own the ETS table. All reads and writes go
  directly through ETS — the GenServer never serializes access.

  Write safety: Mnemosyne dispatches events sequentially per repo, so
  concurrent writes for the same project_id cannot occur.
  """

  use GenServer

  alias Gingko.Memory.SessionMonitorEvent

  @table __MODULE__
  @max_events 50

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec push(SessionMonitorEvent.t()) :: :ok
  def push(%SessionMonitorEvent{project_id: project_id} = event) do
    events =
      case :ets.lookup(@table, project_id) do
        [{_, existing}] -> existing
        [] -> []
      end

    :ets.insert(@table, {project_id, Enum.take([event | events], @max_events)})
    :ok
  end

  @spec list(String.t()) :: [SessionMonitorEvent.t()]
  def list(project_id) when is_binary(project_id) do
    case :ets.lookup(@table, project_id) do
      [{_, events}] -> events
      [] -> []
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
