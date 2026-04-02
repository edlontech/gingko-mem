defmodule Gingko.Memory.ProjectStatsBroadcasterTest do
  use ExUnit.Case, async: false

  alias Gingko.Memory
  alias Gingko.Memory.ProjectStatsBroadcaster
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects
  alias Gingko.Projects.Project
  alias Gingko.Projects.ProjectMemory
  alias Gingko.Projects.Session
  alias Gingko.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Repo.delete_all(Session)
    Repo.delete_all(ProjectMemory)
    Repo.delete_all(Project)

    topic = "projects:stats:test:#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Gingko.PubSub, topic)

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(Gingko.PubSub, topic)
    end)

    %{tmp_dir: tmp_dir, topic: topic}
  end

  defp start_broadcaster!(name, topic) do
    start_supervised!(
      Supervisor.child_spec({ProjectStatsBroadcaster, name: name, topic: topic}, id: name)
    )
  end

  defp build_event(project_id) do
    %SessionMonitorEvent{
      type: :step_appended,
      project_id: project_id,
      repo_id: "repo-#{project_id}",
      timestamp: DateTime.utc_now()
    }
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  test "emits a single broadcast per project when bursts of events arrive in the debounce window",
       %{tmp_dir: tmp_dir, topic: topic} do
    project_key = "broadcast-burst-#{System.unique_integer([:positive])}"

    {:ok, _project} =
      Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    pid = start_broadcaster!(unique_name(:broadcaster_burst), topic)

    for _ <- 1..10, do: send(pid, {:memory_event, build_event(project_key)})

    assert_receive {:project_stats_changed, ^project_key}, 1_500

    refute_receive {:project_stats_changed, ^project_key}, 700
  end

  test "broadcasts per-project independently within the same window", %{
    tmp_dir: tmp_dir,
    topic: topic
  } do
    project_a = "broadcast-a-#{System.unique_integer([:positive])}"
    project_b = "broadcast-b-#{System.unique_integer([:positive])}"

    {:ok, _} = Projects.register_project(%{project_key: project_a, storage_root: tmp_dir})
    {:ok, _} = Projects.register_project(%{project_key: project_b, storage_root: tmp_dir})

    pid = start_broadcaster!(unique_name(:broadcaster_pair), topic)

    for _ <- 1..5 do
      send(pid, {:memory_event, build_event(project_a)})
      send(pid, {:memory_event, build_event(project_b)})
    end

    collected = collect_broadcasts(2)

    assert Enum.sort(collected) == Enum.sort([project_a, project_b])
  end

  test "subscribes to topics for projects registered after boot", %{
    tmp_dir: tmp_dir,
    topic: topic
  } do
    pid = start_broadcaster!(unique_name(:broadcaster_late), topic)

    project_key = "broadcast-late-#{System.unique_integer([:positive])}"

    {:ok, _project} =
      Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

    _ = :sys.get_state(pid)

    Phoenix.PubSub.broadcast(
      Gingko.PubSub,
      Memory.project_monitor_topic(project_key),
      {:memory_event, build_event(project_key)}
    )

    assert_receive {:project_stats_changed, ^project_key}, 1_500
  end

  defp collect_broadcasts(count, acc \\ [], timeout \\ 1_500)

  defp collect_broadcasts(0, acc, _timeout), do: Enum.reverse(acc)

  defp collect_broadcasts(remaining, acc, timeout) do
    receive do
      {:project_stats_changed, project_id} ->
        collect_broadcasts(remaining - 1, [project_id | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
