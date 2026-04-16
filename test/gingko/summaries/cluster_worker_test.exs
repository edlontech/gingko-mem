defmodule Gingko.Summaries.ClusterWorkerTest do
  use Gingko.DataCase, async: false
  use Mimic
  use Oban.Testing, repo: Gingko.Repo

  alias Gingko.Memory
  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterSummarizer
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.PrincipalStateWorker

  setup :set_mimic_global

  setup do
    Mimic.copy(ClusterSummarizer)
    Mimic.copy(Memory)
    Mimic.copy(PrincipalStateWorker)

    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)

    on_exit(fn ->
      Application.delete_env(:gingko, Gingko.Summaries.Config)
    end)

    :ok
  end

  describe "perform/1" do
    test "incremental regen rewrites content, clears dirty flags, truncates deltas, and enqueues principal state worker" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      last_gen = DateTime.add(now, -3600, :second)

      {:ok, cluster} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 40,
          dirty: true,
          dirty_since: now,
          last_generated_at: last_gen,
          regen_count: 5,
          content: "old content"
        })

      {:ok, _} =
        Summaries.append_membership_delta(%{
          project_key: "p",
          tag_node_id: "t",
          memory_node_id: "m1",
          observed_at: DateTime.add(now, -60, :second)
        })

      test_pid = self()

      expect(Memory, :get_nodes, fn "p", ["m1"] ->
        {:ok, [%{node: %{id: "m1", content: "memory body 1"}, metadata: %{}}]}
      end)

      expect(ClusterSummarizer, :summarize, fn ^cluster, memories, :incremental ->
        send(test_pid, {:summarize_called, :incremental, length(memories)})

        {:ok, %{headline: "new headline", content: "new content", frontmatter: %{"extra" => 1}}}
      end)

      expect(PrincipalStateWorker, :enqueue, fn %{project_key: "p"} ->
        send(test_pid, :principal_enqueued)
        :ok
      end)

      assert :ok = perform_job(ClusterWorker, %{project_key: "p", tag_node_id: "t"})

      assert_received {:summarize_called, :incremental, 1}
      assert_received :principal_enqueued

      updated = Summaries.get_cluster("p", "t")
      assert updated.dirty == false
      assert updated.dirty_since == nil
      assert updated.content == "new content"
      assert updated.headline == "new headline"
      assert updated.regen_count == 6
      assert updated.last_generated_at != nil
      assert updated.frontmatter["mode"] == "incremental"
      assert is_integer(updated.frontmatter["latency_ms"])
      assert updated.frontmatter["extra"] == 1

      assert [] = Summaries.deltas_since("p", "t", nil)
    end

    test "full rebuild fires when regen_count is divisible by 50" do
      {:ok, cluster} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 100,
          dirty: true,
          regen_count: 50
        })

      test_pid = self()

      expect(Memory, :memories_linked_to_tag, fn "p", "t" ->
        {:ok, [%{node: %{id: "m1", content: "full body"}, metadata: %{}}]}
      end)

      expect(ClusterSummarizer, :summarize, fn ^cluster, _memories, :full ->
        send(test_pid, :full_mode)
        {:ok, %{headline: "h", content: "c", frontmatter: %{}}}
      end)

      stub(PrincipalStateWorker, :enqueue, fn _ -> :ok end)

      assert :ok = perform_job(ClusterWorker, %{project_key: "p", tag_node_id: "t"})
      assert_received :full_mode

      updated = Summaries.get_cluster("p", "t")
      assert updated.frontmatter["mode"] == "full"
    end

    test "full rebuild fires when memory_count is below 30" do
      {:ok, cluster} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 20,
          dirty: true,
          regen_count: 3
        })

      test_pid = self()

      expect(Memory, :memories_linked_to_tag, fn "p", "t" ->
        {:ok, [%{node: %{id: "m1", content: "body"}, metadata: %{}}]}
      end)

      expect(ClusterSummarizer, :summarize, fn ^cluster, _memories, :full ->
        send(test_pid, :full_fired)
        {:ok, %{headline: "h", content: "c", frontmatter: %{}}}
      end)

      stub(PrincipalStateWorker, :enqueue, fn _ -> :ok end)

      assert :ok = perform_job(ClusterWorker, %{project_key: "p", tag_node_id: "t"})
      assert_received :full_fired
    end

    test "on LLM failure returns {:error, _} and leaves cluster dirty" do
      {:ok, _cluster} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 40,
          dirty: true,
          regen_count: 5,
          content: "unchanged"
        })

      {:ok, _} =
        Summaries.append_membership_delta(%{
          project_key: "p",
          tag_node_id: "t",
          memory_node_id: "m1",
          observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      stub(Memory, :get_nodes, fn _, _ ->
        {:ok, [%{node: %{id: "m1", content: "body"}, metadata: %{}}]}
      end)

      expect(ClusterSummarizer, :summarize, fn _cluster, _memories, :incremental ->
        {:error, :llm_timeout}
      end)

      reject(PrincipalStateWorker, :enqueue, 1)

      assert {:error, :llm_timeout} =
               perform_job(ClusterWorker, %{project_key: "p", tag_node_id: "t"})

      cluster = Summaries.get_cluster("p", "t")
      assert cluster.dirty == true
      assert cluster.content == "unchanged"
      assert cluster.regen_count == 5
      assert [_] = Summaries.deltas_since("p", "t", nil)
    end

    test "discards when cluster row is missing" do
      assert {:discard, "cluster not found"} =
               perform_job(ClusterWorker, %{project_key: "p", tag_node_id: "missing"})
    end

    test "discards when summaries are disabled" do
      Application.put_env(:gingko, Gingko.Summaries.Config, enabled: false)

      assert {:discard, "summaries disabled"} =
               perform_job(ClusterWorker, %{project_key: "p", tag_node_id: "t"})
    end

    test "emits cluster regenerated telemetry event with expected metadata" do
      {:ok, _cluster} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 40,
          dirty: true,
          regen_count: 7
        })

      {:ok, _} =
        Summaries.append_membership_delta(%{
          project_key: "p",
          tag_node_id: "t",
          memory_node_id: "m1",
          observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      stub(Memory, :get_nodes, fn _, _ ->
        {:ok, [%{node: %{id: "m1", content: "b"}, metadata: %{}}]}
      end)

      stub(ClusterSummarizer, :summarize, fn _, _, _ ->
        {:ok, %{headline: "h", content: "c", frontmatter: %{}}}
      end)

      stub(PrincipalStateWorker, :enqueue, fn _ -> :ok end)

      handler_id = {:telemetry_test, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:gingko, :summaries, :cluster, :regenerated],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = perform_job(ClusterWorker, %{project_key: "p", tag_node_id: "t"})

      assert_receive {:telemetry, measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.project_key == "p"
      assert metadata.tag_node_id == "t"
      assert metadata.regen_count == 8
      assert metadata.mode == :incremental
      assert metadata.ok == true
    end
  end

  describe "enqueue/1" do
    test "inserts a job and dedupes by (project_key, tag_node_id)" do
      assert {:ok, _job} =
               ClusterWorker.enqueue(%{project_key: "p", tag_node_id: "t"})

      assert {:ok, _job2} =
               ClusterWorker.enqueue(%{project_key: "p", tag_node_id: "t"})

      assert [_only_one] =
               all_enqueued(worker: ClusterWorker, args: %{project_key: "p", tag_node_id: "t"})
    end
  end
end
