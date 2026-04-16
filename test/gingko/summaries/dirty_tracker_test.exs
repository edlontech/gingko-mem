defmodule Gingko.Summaries.DirtyTrackerTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.DirtyTracker

  @event [:mnemosyne, :memory, :appended]

  setup :set_mimic_global

  setup do
    Mimic.copy(ClusterWorker)

    Application.put_env(:gingko, Gingko.Summaries.Config,
      enabled: true,
      hot_tags_k: 2
    )

    DirtyTracker.detach()
    :ok = DirtyTracker.attach()

    on_exit(fn ->
      DirtyTracker.detach()
      Application.delete_env(:gingko, Gingko.Summaries.Config)
      DirtyTracker.attach()
    end)

    :ok
  end

  describe "handle_event/4" do
    test "admits first K tags, upserts cluster rows, and appends deltas" do
      stub(ClusterWorker, :enqueue, fn _args -> :ok end)

      emit("p", "n1", [
        %{id: "t1", label: "Auth", memory_count: 5},
        %{id: "t2", label: "Graph", memory_count: 3}
      ])

      clusters = Summaries.list_clusters("p")
      assert length(clusters) == 2

      assert Enum.any?(clusters, fn c ->
               c.tag_node_id == "t1" and c.slug == "auth" and c.dirty == true
             end)

      assert Enum.any?(clusters, fn c ->
               c.tag_node_id == "t2" and c.slug == "graph" and c.dirty == true
             end)

      assert [%{memory_node_id: "n1"}] = Summaries.deltas_since("p", "t1", nil)
      assert [%{memory_node_id: "n1"}] = Summaries.deltas_since("p", "t2", nil)
    end

    test "rejects a new tag that doesn't beat the min count once table is full" do
      stub(ClusterWorker, :enqueue, fn _args -> :ok end)

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10,
          dirty: false
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Graph",
          slug: "graph",
          memory_count: 8,
          dirty: false
        })

      emit("p", "n2", [%{id: "t3", label: "LowVolume", memory_count: 1}])

      assert Summaries.get_cluster("p", "t3") == nil
      assert Summaries.deltas_since("p", "t3", nil) == []
    end

    test "admits a new tag whose memory_count exceeds the current minimum" do
      stub(ClusterWorker, :enqueue, fn _args -> :ok end)

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10,
          dirty: false
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Graph",
          slug: "graph",
          memory_count: 4,
          dirty: false
        })

      emit("p", "n3", [%{id: "t3", label: "HighVolume", memory_count: 7}])

      assert %{tag_node_id: "t3", slug: "highvolume", dirty: true} =
               Summaries.get_cluster("p", "t3")
    end

    test "always admits a tag that already has a cluster row" do
      stub(ClusterWorker, :enqueue, fn _args -> :ok end)

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10,
          dirty: false
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Graph",
          slug: "graph",
          memory_count: 8,
          dirty: false
        })

      emit("p", "n4", [%{id: "t1", label: "Auth", memory_count: 12}])

      assert %{memory_count: 12, dirty: true} = Summaries.get_cluster("p", "t1")
      assert [%{memory_node_id: "n4"}] = Summaries.deltas_since("p", "t1", nil)
    end

    test "falls back to tag_id when label is empty or non-binary" do
      stub(ClusterWorker, :enqueue, fn _args -> :ok end)

      emit("p", "n5", [
        %{id: "tag-no-label", label: "!!!", memory_count: 2},
        %{id: "tag-nil-label", label: nil, memory_count: 2}
      ])

      assert %{slug: "tag-no-label"} = Summaries.get_cluster("p", "tag-no-label")
      assert %{slug: "tag-nil-label"} = Summaries.get_cluster("p", "tag-nil-label")
    end

    test "is a no-op when Config.enabled? is false" do
      stub(ClusterWorker, :enqueue, fn _args -> flunk("should not enqueue when disabled") end)

      Application.put_env(:gingko, Gingko.Summaries.Config, enabled: false)

      emit("p", "n1", [%{id: "t1", label: "Auth", memory_count: 5}])

      assert Summaries.list_clusters("p") == []
      assert Summaries.deltas_since("p", "t1", nil) == []
    end

    test "enqueues ClusterWorker for each admitted tag" do
      test_pid = self()

      expect(ClusterWorker, :enqueue, 2, fn args ->
        send(test_pid, {:enqueued, args})
        :ok
      end)

      emit("p", "n1", [
        %{id: "t1", label: "Auth", memory_count: 5},
        %{id: "t2", label: "Graph", memory_count: 3}
      ])

      assert_received {:enqueued, %{project_key: "p", tag_node_id: "t1"}}
      assert_received {:enqueued, %{project_key: "p", tag_node_id: "t2"}}
    end

    test "ignores events without project_key, node, or linked_tags" do
      stub(ClusterWorker, :enqueue, fn _args -> :ok end)

      :telemetry.execute(@event, %{}, %{project_key: "p"})
      :telemetry.execute(@event, %{}, %{node: %{id: "n"}, linked_tags: []})
      :telemetry.execute(@event, %{}, %{project_key: "p", node: %{id: "n"}, linked_tags: []})

      assert Summaries.list_clusters("p") == []
    end

    test "stays attached after a persistence operation raises" do
      Mimic.copy(Summaries)

      stub(ClusterWorker, :enqueue, fn _args -> :ok end)

      stub(Summaries, :upsert_cluster, fn _attrs ->
        raise ArgumentError, "boom"
      end)

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          emit("p", "n1", [%{id: "t1", label: "Auth", memory_count: 5}])
        end)

      assert log =~ "DirtyTracker handler error"

      handlers = :telemetry.list_handlers([:mnemosyne, :memory, :appended])

      assert Enum.any?(handlers, fn
               %{id: {DirtyTracker, :mnemosyne_appended}} -> true
               _ -> false
             end)
    end
  end

  defp emit(project_key, node_id, tags) do
    :telemetry.execute(
      @event,
      %{},
      %{project_key: project_key, node: %{id: node_id}, linked_tags: tags}
    )
  end
end
