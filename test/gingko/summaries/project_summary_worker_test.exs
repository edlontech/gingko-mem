defmodule Gingko.Summaries.ProjectSummaryWorkerTest do
  use Gingko.DataCase, async: false
  use Oban.Testing, repo: Gingko.Repo
  use Mimic

  alias Gingko.Memory
  alias Gingko.Summaries
  alias Gingko.Summaries.Config
  alias Gingko.Summaries.ProjectSummarizer
  alias Gingko.Summaries.ProjectSummaryWorker

  setup :set_mimic_global

  setup do
    Mimic.copy(Memory)
    Mimic.copy(ProjectSummarizer)
    Mimic.copy(Config)

    Gingko.Repo.query!("DELETE FROM oban_jobs")

    stub(Config, :enabled?, fn -> true end)
    stub(Config, :regen_debounce_seconds, fn -> 60 end)
    stub(Config, :summary_memory_count, fn -> 50 end)

    :ok
  end

  describe "perform/1" do
    test "writes the summary section on a successful regen" do
      stub(Memory, :latest_memories, fn
        %{project_id: "p", top_k: top_k, types: [:semantic]} ->
          {:ok,
           %{
             project_id: "p",
             memories: List.duplicate(%{node: %{proposition: "stable fact"}}, top_k)
           }}

        %{project_id: "p", top_k: top_k, types: [:episodic]} ->
          {:ok,
           %{
             project_id: "p",
             memories:
               List.duplicate(
                 %{node: %{observation: "saw x", action: "did y"}},
                 top_k
               )
           }}
      end)

      stub(ProjectSummarizer, :summarize, fn _inputs, _charter ->
        {:ok,
         %{
           content: "## Purpose\n\nThe constitution body.",
           frontmatter: %{topics: ["focus"], key_concepts: []}
         }}
      end)

      assert :ok = perform_job(ProjectSummaryWorker, %{project_key: "p"})

      assert %{content: content, frontmatter: %{"topics" => ["focus"]}} =
               Summaries.get_section("p", "summary")

      assert content =~ "constitution body"
    end

    test "splits the memory budget between semantic and episodic with a 75/25 bias" do
      test_pid = self()

      stub(Memory, :latest_memories, fn %{top_k: top_k, types: [type]} ->
        send(test_pid, {:fetch, type, top_k})
        {:ok, %{project_id: "p", memories: []}}
      end)

      stub(ProjectSummarizer, :summarize, fn _, _ ->
        {:ok, %{content: "body", frontmatter: %{topics: [], key_concepts: []}}}
      end)

      assert :ok = perform_job(ProjectSummaryWorker, %{project_key: "p"})

      assert_receive {:fetch, :semantic, 38}
      assert_receive {:fetch, :episodic, 12}
    end

    test "passes the charter content to the summarizer when present" do
      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "charter",
          content: "ship small"
        })

      stub(Memory, :latest_memories, fn _ -> {:ok, %{project_id: "p", memories: []}} end)

      test_pid = self()

      stub(ProjectSummarizer, :summarize, fn inputs, charter ->
        send(test_pid, {:summarize, inputs, charter})

        {:ok, %{content: "body", frontmatter: %{topics: [], key_concepts: []}}}
      end)

      assert :ok = perform_job(ProjectSummaryWorker, %{project_key: "p"})

      assert_receive {:summarize, %{semantic: [], episodic: []}, "ship small"}
    end

    test "discards when summary section is locked" do
      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: "p",
          kind: "summary",
          content: "pinned",
          locked: true
        })

      stub(ProjectSummarizer, :summarize, fn _, _ ->
        flunk("should not call summarizer when locked")
      end)

      assert {:discard, "summary locked"} =
               perform_job(ProjectSummaryWorker, %{project_key: "p"})
    end

    test "discards when summaries are disabled" do
      stub(Config, :enabled?, fn -> false end)

      stub(ProjectSummarizer, :summarize, fn _, _ ->
        flunk("should not call summarizer when disabled")
      end)

      assert {:discard, "summaries disabled"} =
               perform_job(ProjectSummaryWorker, %{project_key: "p"})
    end

    test "propagates summarizer errors so Oban retries" do
      stub(Memory, :latest_memories, fn _ -> {:ok, %{project_id: "p", memories: []}} end)
      stub(ProjectSummarizer, :summarize, fn _, _ -> {:error, :rate_limited} end)

      assert {:error, :rate_limited} =
               perform_job(ProjectSummaryWorker, %{project_key: "p"})
    end
  end

  describe "enqueue/1" do
    test "schedules a debounced job and dedupes within the debounce window" do
      assert {:ok, %Oban.Job{id: id1}} = ProjectSummaryWorker.enqueue(%{project_key: "p"})

      assert {:ok, %Oban.Job{id: id2}} = ProjectSummaryWorker.enqueue(%{project_key: "p"})

      assert id1 == id2

      assert [_single] = all_enqueued(worker: ProjectSummaryWorker, args: %{project_key: "p"})
    end
  end
end
