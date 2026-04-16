defmodule Gingko.Summaries.PrincipalStateWorkerTest do
  use Gingko.DataCase, async: false
  use Mimic
  use Oban.Testing, repo: Gingko.Repo

  alias Gingko.Summaries
  alias Gingko.Summaries.PrincipalStateSummarizer
  alias Gingko.Summaries.PrincipalStateWorker

  setup :set_mimic_global

  setup do
    Mimic.copy(PrincipalStateSummarizer)

    Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)

    on_exit(fn ->
      Application.delete_env(:gingko, Gingko.Summaries.Config)
    end)

    :ok
  end

  describe "perform/1" do
    test "upserts the :state section row with the composed content and source cluster ids" do
      {:ok, _c1} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Auth",
          slug: "auth",
          memory_count: 10,
          headline: "auth headline",
          dirty: false
        })

      {:ok, _c2} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Graph",
          slug: "graph",
          memory_count: 8,
          headline: "graph headline",
          dirty: false
        })

      {:ok, _charter} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "charter body"
        })

      expect(PrincipalStateSummarizer, :summarize, fn clusters, charter ->
        assert length(clusters) == 2
        assert charter != nil
        {:ok, %{content: "state body", frontmatter: %{"extra" => "yes"}}}
      end)

      assert :ok = perform_job(PrincipalStateWorker, %{project_key: "p"})

      state = Summaries.get_section("p", "state")
      assert state != nil
      assert state.content == "state body"
      assert state.frontmatter["extra"] == "yes"

      ids = state.frontmatter["source_cluster_ids"]
      assert is_list(ids)
      assert Enum.sort(ids) == ["t1", "t2"]
    end

    test "ignores locked clusters when summarizing" do
      {:ok, _c1} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Active",
          slug: "active",
          memory_count: 10,
          dirty: false,
          locked: false
        })

      {:ok, _c2} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Pinned",
          slug: "pinned",
          memory_count: 20,
          dirty: false,
          locked: true
        })

      expect(PrincipalStateSummarizer, :summarize, fn clusters, _charter ->
        assert [%{tag_node_id: "t1"}] = clusters
        {:ok, %{content: "body", frontmatter: %{}}}
      end)

      assert :ok = perform_job(PrincipalStateWorker, %{project_key: "p"})

      state = Summaries.get_section("p", "state")
      assert state.frontmatter["source_cluster_ids"] == ["t1"]
    end

    test "passes nil charter when charter row is missing" do
      {:ok, _c1} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Active",
          slug: "active",
          memory_count: 10,
          dirty: false
        })

      expect(PrincipalStateSummarizer, :summarize, fn _clusters, charter ->
        assert charter == nil
        {:ok, %{content: "body", frontmatter: %{}}}
      end)

      assert :ok = perform_job(PrincipalStateWorker, %{project_key: "p"})
    end

    test "passes nil charter when charter content is empty" do
      {:ok, _c1} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Active",
          slug: "active",
          memory_count: 10,
          dirty: false
        })

      {:ok, _charter} =
        Summaries.upsert_section(%{project_key: "p", kind: "charter", content: ""})

      expect(PrincipalStateSummarizer, :summarize, fn _clusters, charter ->
        assert charter == nil
        {:ok, %{content: "body", frontmatter: %{}}}
      end)

      assert :ok = perform_job(PrincipalStateWorker, %{project_key: "p"})
    end

    test "does not overwrite a locked :state row" do
      {:ok, _c1} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Active",
          slug: "active",
          memory_count: 10,
          dirty: false
        })

      {:ok, _state} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "state",
          content: "manually written",
          locked: true
        })

      reject(PrincipalStateSummarizer, :summarize, 2)

      assert {:discard, "state locked"} = perform_job(PrincipalStateWorker, %{project_key: "p"})

      state = Summaries.get_section("p", "state")
      assert state.content == "manually written"
      assert state.locked == true
    end

    test "discards when summaries are disabled" do
      Application.put_env(:gingko, Gingko.Summaries.Config, enabled: false)

      assert {:discard, "summaries disabled"} =
               perform_job(PrincipalStateWorker, %{project_key: "p"})
    end

    test "emits principal regenerated telemetry event with expected metadata" do
      {:ok, _c1} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t1",
          tag_label: "Active",
          slug: "active",
          memory_count: 10,
          dirty: false
        })

      {:ok, _c2} =
        Summaries.upsert_cluster(%{
          project_key: "p",
          tag_node_id: "t2",
          tag_label: "Second",
          slug: "second",
          memory_count: 5,
          dirty: false
        })

      stub(PrincipalStateSummarizer, :summarize, fn _, _ ->
        {:ok, %{content: "body", frontmatter: %{}}}
      end)

      handler_id = {:telemetry_test, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:gingko, :summaries, :principal, :regenerated],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = perform_job(PrincipalStateWorker, %{project_key: "p"})

      assert_receive {:telemetry, measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.project_key == "p"
      assert metadata.source_cluster_count == 2
      assert metadata.ok == true
    end
  end

  describe "enqueue/1" do
    test "inserts a scheduled job using the configured debounce window" do
      Application.put_env(:gingko, Gingko.Summaries.Config,
        enabled: true,
        principal_regen_debounce_seconds: 45
      )

      project_key = "enqueue-#{System.unique_integer([:positive])}"

      assert {:ok, _job} = PrincipalStateWorker.enqueue(%{project_key: project_key})

      assert [_job] =
               all_enqueued(worker: PrincipalStateWorker, args: %{project_key: project_key})
    end
  end
end
