defmodule Gingko.SummariesTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Memory
  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterMembershipDelta
  alias Gingko.Summaries.ClusterSummary
  alias Gingko.Summaries.Playbook
  alias Gingko.Summaries.PrincipalMemorySection

  setup :set_mimic_global

  describe "principal sections" do
    test "upsert_section inserts then replaces by (project_key, kind)" do
      assert {:ok, %PrincipalMemorySection{id: first_id}} =
               Summaries.upsert_section(%{
                 project_key: "p",
                 kind: "playbook",
                 content: "v1"
               })

      assert {:ok, %PrincipalMemorySection{id: second_id}} =
               Summaries.upsert_section(%{
                 project_key: "p",
                 kind: "playbook",
                 content: "v2"
               })

      assert first_id == second_id
      assert %{content: "v2"} = Summaries.get_section("p", "playbook")
    end

    test "rejects unknown kind" do
      assert {:error, changeset} =
               Summaries.upsert_section(%{
                 project_key: "p",
                 kind: "bogus",
                 content: ""
               })

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "list_sections scopes to project_key" do
      {:ok, _} =
        Summaries.upsert_section(%{project_key: "a", kind: "playbook", content: "A"})

      {:ok, _} =
        Summaries.upsert_section(%{project_key: "b", kind: "playbook", content: "B"})

      assert [%{project_key: "a"}] = Summaries.list_sections("a")
    end

    test "get_section returns nil when missing" do
      refute Summaries.get_section("p", "charter")
    end
  end

  describe "clusters" do
    test "upsert_cluster inserts then replaces by (project_key, tag_node_id)" do
      {:ok, %ClusterSummary{id: id}} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "t1", headline: "initial"))

      {:ok, %ClusterSummary{id: updated_id, headline: "updated"}} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "t1", headline: "updated"))

      assert id == updated_id
    end

    test "list_dirty_clusters omits clean and locked rows" do
      {:ok, _dirty} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "a", dirty: true))

      {:ok, _clean} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "b", dirty: false))

      {:ok, _locked} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "c", dirty: true, locked: true))

      assert [%{tag_node_id: "a"}] = Summaries.list_dirty_clusters("p")
    end

    test "get_cluster and get_cluster_by_slug resolve rows" do
      {:ok, _} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "t1", slug: "auth"))

      assert %{slug: "auth"} = Summaries.get_cluster("p", "t1")
      assert %{tag_node_id: "t1"} = Summaries.get_cluster_by_slug("p", "auth")
      refute Summaries.get_cluster("p", "unknown")
      refute Summaries.get_cluster_by_slug("p", "unknown")
    end

    test "update_cluster mutates fields" do
      {:ok, cluster} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "t1", headline: "old"))

      assert {:ok, %{headline: "new"}} = Summaries.update_cluster(cluster, %{headline: "new"})
    end

    test "list_clusters orders by memory_count desc" do
      {:ok, _} = Summaries.upsert_cluster(base_cluster(tag_node_id: "a", memory_count: 3))
      {:ok, _} = Summaries.upsert_cluster(base_cluster(tag_node_id: "b", memory_count: 10))
      {:ok, _} = Summaries.upsert_cluster(base_cluster(tag_node_id: "c", memory_count: 5))

      assert [%{tag_node_id: "b"}, %{tag_node_id: "c"}, %{tag_node_id: "a"}] =
               Summaries.list_clusters("p")
    end
  end

  describe "finalize_cluster_regen/5" do
    test "stringifies atom keys recursively through nested maps and lists" do
      {:ok, cluster} =
        Summaries.upsert_cluster(base_cluster(tag_node_id: "t-nested", regen_count: 0))

      result = %{
        headline: "h",
        content: "c",
        frontmatter: %{
          model: "claude",
          nested: %{inner: %{leaf: 1}},
          list: [%{tag: "x"}, %{tag: "y"}]
        }
      }

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, updated} =
               Summaries.finalize_cluster_regen(cluster, result, :incremental, 42, now)

      assert updated.frontmatter["model"] == "claude"
      assert updated.frontmatter["nested"] == %{"inner" => %{"leaf" => 1}}
      assert updated.frontmatter["list"] == [%{"tag" => "x"}, %{"tag" => "y"}]
      assert updated.frontmatter["mode"] == "incremental"
      assert updated.frontmatter["latency_ms"] == 42
    end
  end

  describe "membership deltas" do
    test "append_membership_delta persists a row" do
      assert {:ok, %ClusterMembershipDelta{}} =
               Summaries.append_membership_delta(%{
                 project_key: "p",
                 tag_node_id: "t",
                 memory_node_id: "m",
                 observed_at: ~U[2026-04-01 00:00:00Z]
               })
    end

    test "deltas_since filters by observed_at and delete_deltas_up_to truncates" do
      t0 = ~U[2026-04-01 00:00:00Z]
      t1 = ~U[2026-04-02 00:00:00Z]

      for ts <- [t0, t1] do
        {:ok, _} =
          Summaries.append_membership_delta(%{
            project_key: "p",
            tag_node_id: "t",
            memory_node_id: Ecto.UUID.generate(),
            observed_at: ts
          })
      end

      assert length(Summaries.deltas_since("p", "t", t0)) == 1
      assert length(Summaries.deltas_since("p", "t", nil)) == 2
      assert {1, _} = Summaries.delete_deltas_up_to("p", "t", t0)
      assert length(Summaries.deltas_since("p", "t", nil)) == 1
    end
  end

  describe "render_primer/2" do
    setup do
      Mimic.copy(Gingko.Memory)
      :ok
    end

    test "renders playbook content, cluster headline, and recent memory body on the happy path" do
      project_key = "primer-happy-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "playbook",
          content: "# Custom Playbook\n\nSeeded body."
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: project_key,
          tag_node_id: "tag-1",
          tag_label: "auth",
          slug: "auth-slug",
          headline: "auth is the topic",
          memory_count: 4,
          last_generated_at: ~U[2026-04-20 00:00:00Z],
          dirty: false,
          locked: false
        })

      stub(Memory, :latest_memories, fn %{project_id: ^project_key} ->
        {:ok,
         %{
           project_id: project_key,
           memories: [
             %{
               node: %{type: "semantic", proposition: "tail memory body"},
               metadata: %{created_at: ~U[2026-04-20 12:00:00Z]}
             }
           ]
         }}
      end)

      assert {:ok, rendered} = Summaries.render_primer(project_key)

      assert rendered =~ "# Custom Playbook"
      assert rendered =~ "Seeded body."
      assert rendered =~ "**auth-slug**"
      assert rendered =~ "— auth is the topic"
      assert rendered =~ "tail memory body"
      assert rendered =~ "<!-- region:recent_memories -->"
    end

    test "falls back to Playbook.markdown/0 when the playbook row is missing" do
      project_key = "primer-fallback-#{System.unique_integer([:positive])}"

      stub(Memory, :latest_memories, fn %{project_id: ^project_key} ->
        {:ok, %{project_id: project_key, memories: []}}
      end)

      assert {:ok, rendered} = Summaries.render_primer(project_key)

      refute Summaries.get_section(project_key, "playbook")
      assert rendered =~ Playbook.markdown()
    end

    test "renders empty recent tail when Memory.latest_memories/1 errors" do
      project_key = "primer-errors-#{System.unique_integer([:positive])}"

      stub(Memory, :latest_memories, fn %{project_id: ^project_key} ->
        {:error, %{code: :project_not_open, message: "repo not open"}}
      end)

      assert {:ok, rendered} = Summaries.render_primer(project_key)

      assert rendered =~ "<!-- region:recent_memories -->"
      assert rendered =~ "_No recent memories._"
    end
  end

  defp base_cluster(overrides) do
    Map.merge(
      %{
        project_key: "p",
        tag_node_id: "t",
        tag_label: "t",
        slug: "t",
        memory_count: 1,
        dirty: true,
        locked: false
      },
      Map.new(overrides)
    )
  end
end
