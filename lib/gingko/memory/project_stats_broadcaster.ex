defmodule Gingko.Memory.ProjectStatsBroadcaster do
  @moduledoc """
  Debounces per-project `SessionMonitorEvent`s into one `projects:stats`
  broadcast per 500ms window per project.

  Powers the `/projects` card grid without re-rendering per `step_appended`.
  The broadcaster subscribes to each registered project's monitor topic at
  boot and refreshes its subscription set whenever `Gingko.Projects`
  announces a change via `:projects_changed`.
  """

  use GenServer

  alias Gingko.Memory
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects

  @debounce_ms 500

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Projects.subscribe_projects()

    topic = Keyword.get(opts, :topic, Memory.projects_stats_topic())

    state = %{
      timers: %{},
      subscriptions: MapSet.new(),
      topic: topic
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    {:noreply, %{state | subscriptions: refresh_subscriptions(state.subscriptions)}}
  end

  @impl true
  def handle_info({:memory_event, %SessionMonitorEvent{project_id: project_id}}, state)
      when is_binary(project_id) do
    {:noreply, schedule(state, project_id)}
  end

  def handle_info(:projects_changed, state) do
    {:noreply, %{state | subscriptions: refresh_subscriptions(state.subscriptions)}}
  end

  def handle_info({:flush, project_id}, state) do
    Phoenix.PubSub.broadcast(
      Gingko.PubSub,
      state.topic,
      {:project_stats_changed, project_id}
    )

    {:noreply, %{state | timers: Map.delete(state.timers, project_id)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule(%{timers: timers} = state, project_id) do
    if Map.has_key?(timers, project_id) do
      state
    else
      ref = Process.send_after(self(), {:flush, project_id}, @debounce_ms)
      %{state | timers: Map.put(timers, project_id, ref)}
    end
  end

  defp refresh_subscriptions(current) do
    desired =
      Projects.list_projects()
      |> Enum.map(& &1.project_key)
      |> MapSet.new()

    Enum.each(MapSet.difference(desired, current), fn project_key ->
      Phoenix.PubSub.subscribe(Gingko.PubSub, Memory.project_monitor_topic(project_key))
    end)

    desired
  end
end
