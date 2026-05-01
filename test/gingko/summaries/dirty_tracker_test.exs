defmodule Gingko.Summaries.DirtyTrackerTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Summaries.Config
  alias Gingko.Summaries.DirtyTracker
  alias Gingko.Summaries.ProjectSummaryWorker

  @event [:mnemosyne, :memory, :appended]

  setup :set_mimic_global

  setup do
    Mimic.copy(Config)
    Mimic.copy(ProjectSummaryWorker)

    DirtyTracker.detach()
    :ok = DirtyTracker.attach()

    on_exit(fn ->
      DirtyTracker.detach()
      DirtyTracker.attach()
    end)

    :ok
  end

  describe "handle_event/4" do
    test "enqueues ProjectSummaryWorker for the project on memory append" do
      stub(Config, :enabled?, fn -> true end)

      test_pid = self()

      expect(ProjectSummaryWorker, :enqueue, fn args ->
        send(test_pid, {:enqueued, args})
        {:ok, %Oban.Job{id: 1}}
      end)

      :telemetry.execute(@event, %{}, %{project_key: "p"})

      assert_receive {:enqueued, %{project_key: "p"}}
    end

    test "is a no-op when Config.enabled? is false" do
      stub(Config, :enabled?, fn -> false end)

      stub(ProjectSummaryWorker, :enqueue, fn _ ->
        flunk("should not enqueue when disabled")
      end)

      :telemetry.execute(@event, %{}, %{project_key: "p"})
    end

    test "ignores events without project_key" do
      stub(Config, :enabled?, fn -> true end)

      stub(ProjectSummaryWorker, :enqueue, fn _ ->
        flunk("should not enqueue without project_key")
      end)

      :telemetry.execute(@event, %{}, %{})
    end

    test "stays attached after the worker raises" do
      stub(Config, :enabled?, fn -> true end)

      stub(ProjectSummaryWorker, :enqueue, fn _ -> raise ArgumentError, "boom" end)

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          :telemetry.execute(@event, %{}, %{project_key: "p"})
        end)

      assert log =~ "DirtyTracker handler error"

      handlers = :telemetry.list_handlers(@event)

      assert Enum.any?(handlers, fn
               %{id: {DirtyTracker, :mnemosyne_appended}} -> true
               _ -> false
             end)
    end
  end
end
