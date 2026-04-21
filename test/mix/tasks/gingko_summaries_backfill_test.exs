defmodule Mix.Tasks.Gingko.Summaries.BackfillTest do
  use Gingko.DataCase, async: false
  use Mimic
  use Oban.Testing, repo: Gingko.Repo

  alias Gingko.Memory
  alias Gingko.Projects
  alias Gingko.Projects.Project
  alias Gingko.Projects.ProjectMemory
  alias Gingko.Projects.Session
  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterWorker
  alias Mix.Tasks.Gingko.Summaries.Backfill

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup %{tmp_dir: tmp_dir} do
    Repo.delete_all(Session)
    Repo.delete_all(ProjectMemory)
    Repo.delete_all(Project)
    Repo.query!("DELETE FROM oban_jobs")

    Mimic.copy(Memory)

    %{tmp_dir: tmp_dir}
  end

  describe "run/1" do
    test "is a no-op when there are no projects" do
      assert :ok = Backfill.run([])

      assert [] = all_enqueued(worker: ClusterWorker)
      assert [] = Summaries.list_sections("none")
    end

    test "seeds playbook for every existing project", %{tmp_dir: tmp_dir} do
      stub(Memory, :top_tags, fn _project_key, _k -> {:ok, []} end)

      project_a = "backfill-a-#{System.unique_integer([:positive])}"
      project_b = "backfill-b-#{System.unique_integer([:positive])}"

      {:ok, _} = Projects.register_project(%{project_key: project_a, storage_root: tmp_dir})
      {:ok, _} = Projects.register_project(%{project_key: project_b, storage_root: tmp_dir})

      assert :ok = Backfill.run([])

      assert %Summaries.PrincipalMemorySection{kind: "playbook", content: content_a} =
               Summaries.get_section(project_a, "playbook")

      assert %Summaries.PrincipalMemorySection{kind: "playbook", content: content_b} =
               Summaries.get_section(project_b, "playbook")

      assert content_a == Summaries.Playbook.markdown()
      assert content_b == Summaries.Playbook.markdown()
    end

    test "enqueues ClusterWorker for each top tag of each project", %{tmp_dir: tmp_dir} do
      project_key = "backfill-tags-#{System.unique_integer([:positive])}"

      {:ok, _} = Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      top_tags = [
        %{id: "tag-auth", label: "Auth", memory_count: 42},
        %{id: "tag-graph", label: "Graph", memory_count: 17}
      ]

      expect(Memory, :top_tags, fn ^project_key, _k -> {:ok, top_tags} end)

      assert :ok = Backfill.run([])

      enqueued = all_enqueued(worker: ClusterWorker)
      assert length(enqueued) == 2

      tag_ids =
        enqueued
        |> Enum.map(& &1.args["tag_node_id"])
        |> Enum.sort()

      assert tag_ids == ["tag-auth", "tag-graph"]

      assert Enum.all?(enqueued, fn job -> job.args["project_key"] == project_key end)
    end

    test "upserts cluster rows for each top tag so the primer has something to render",
         %{tmp_dir: tmp_dir} do
      project_key = "backfill-upsert-#{System.unique_integer([:positive])}"

      {:ok, _} = Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      expect(Memory, :top_tags, fn ^project_key, _k ->
        {:ok, [%{id: "tag-alpha", label: "Alpha Theme", memory_count: 9}]}
      end)

      assert :ok = Backfill.run([])

      cluster = Summaries.get_cluster(project_key, "tag-alpha")
      assert cluster.tag_label == "Alpha Theme"
      assert cluster.memory_count == 9
      assert cluster.dirty == true
      assert cluster.slug == "alpha-theme"
    end

    test "is idempotent across repeated runs", %{tmp_dir: tmp_dir} do
      project_key = "backfill-idem-#{System.unique_integer([:positive])}"

      {:ok, _} = Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      stub(Memory, :top_tags, fn ^project_key, _k ->
        {:ok, [%{id: "tag-x", label: "X", memory_count: 5}]}
      end)

      assert :ok = Backfill.run([])
      assert [_single_job] = all_enqueued(worker: ClusterWorker)

      assert :ok = Backfill.run([])
      assert [_single_job] = all_enqueued(worker: ClusterWorker)

      assert [_single_playbook] =
               Summaries.list_sections(project_key)
               |> Enum.filter(&(&1.kind == "playbook"))

      assert [_single_cluster] =
               Summaries.list_clusters(project_key)
               |> Enum.filter(&(&1.tag_node_id == "tag-x"))
    end

    test "seeds playbook and enqueues project-scoped jobs for two distinct projects",
         %{tmp_dir: tmp_dir} do
      project_a = "backfill-multi-a-#{System.unique_integer([:positive])}"
      project_b = "backfill-multi-b-#{System.unique_integer([:positive])}"

      {:ok, _} = Projects.register_project(%{project_key: project_a, storage_root: tmp_dir})
      {:ok, _} = Projects.register_project(%{project_key: project_b, storage_root: tmp_dir})

      stub(Memory, :top_tags, fn
        ^project_a, _k -> {:ok, [%{id: "tag-a1", label: "Alpha", memory_count: 5}]}
        ^project_b, _k -> {:ok, [%{id: "tag-b1", label: "Bravo", memory_count: 3}]}
      end)

      assert :ok = Backfill.run([])

      assert %Summaries.PrincipalMemorySection{kind: "playbook"} =
               Summaries.get_section(project_a, "playbook")

      assert %Summaries.PrincipalMemorySection{kind: "playbook"} =
               Summaries.get_section(project_b, "playbook")

      pairs =
        [worker: ClusterWorker]
        |> all_enqueued()
        |> Enum.map(fn job -> {job.args["project_key"], job.args["tag_node_id"]} end)
        |> Enum.sort()

      assert pairs == [{project_a, "tag-a1"}, {project_b, "tag-b1"}]

      cluster_a = Summaries.get_cluster(project_a, "tag-a1")
      cluster_b = Summaries.get_cluster(project_b, "tag-b1")

      assert cluster_a.tag_label == "Alpha"
      assert cluster_a.memory_count == 5
      assert cluster_b.tag_label == "Bravo"
      assert cluster_b.memory_count == 3
    end

    test "skips cluster enqueues when top_tags returns an error", %{tmp_dir: tmp_dir} do
      project_key = "backfill-err-#{System.unique_integer([:positive])}"

      {:ok, _} = Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      expect(Memory, :top_tags, fn ^project_key, _k ->
        {:error, %{code: :something_wrong, message: "graph blew up"}}
      end)

      assert :ok = Backfill.run([])

      assert %Summaries.PrincipalMemorySection{} =
               Summaries.get_section(project_key, "playbook")

      assert [] = all_enqueued(worker: ClusterWorker)
    end
  end
end
