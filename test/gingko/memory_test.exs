defmodule Gingko.MemoryTest do
  use ExUnit.Case, async: false
  use Mimic
  import ExUnit.CaptureLog

  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult
  alias Mnemosyne.Pipeline.Retrieval.TouchedNode

  setup :set_mimic_global

  test "builds mnemosyne supervisor opts from app config" do
    opts = Gingko.Memory.mnemosyne_supervisor_opts()

    assert %Mnemosyne.Config{} = Keyword.fetch!(opts, :config)
    assert Gingko.TestSupport.Mnemosyne.MockLLM == Keyword.fetch!(opts, :llm)
    assert Gingko.TestSupport.Mnemosyne.MockEmbedding == Keyword.fetch!(opts, :embedding)
    assert Gingko.Memory.Notifier == Keyword.fetch!(opts, :notifier)
  end

  test "exposes project monitor helpers" do
    project_id = "monitor-" <> Integer.to_string(System.unique_integer([:positive]))

    assert "project:#{project_id}:memory" == Gingko.Memory.project_monitor_topic(project_id)

    assert %{
             project_id: ^project_id,
             active_sessions: [],
             recent_events: [],
             counters: %{active_sessions: 0, recent_commits: 0, recent_recalls: 0}
           } = Gingko.Memory.project_monitor_snapshot(project_id)
  end

  test "open_project is idempotent" do
    project_id = "memory-test-" <> Integer.to_string(System.unique_integer([:positive]))

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      if repo_id in Mnemosyne.list_repos() do
        :ok = Mnemosyne.close_repo(repo_id)
      end
    end)

    assert {:ok, %{already_open?: false, repo_id: repo_id}} =
             Gingko.Memory.open_project(project_id)

    assert {:ok, %{already_open?: true, repo_id: ^repo_id}} =
             Gingko.Memory.open_project(project_id)
  end

  describe "per-project extraction overlay" do
    @tag capture_log: true
    test "threads project-specific config into Mnemosyne.open_repo/2" do
      Mimic.copy(Mnemosyne)

      project_id = "overlay-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, _} = Gingko.Projects.register_project(%{project_key: project_id})

      {:ok, _} =
        Gingko.Projects.update_extraction_overlay(project_id, %{
          "base" => "coding",
          "steps" => %{"get_semantic" => "per-project instruction"}
        })

      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      test_pid = self()

      stub(Mnemosyne, :list_repos, fn -> [] end)

      expect(Mnemosyne, :open_repo, fn ^repo_id, opts ->
        send(test_pid, {:open_repo_opts, opts})
        {:ok, self()}
      end)

      on_exit(fn ->
        if repo_id in Mnemosyne.list_repos() do
          :ok = Mnemosyne.close_repo(repo_id)
        end
      end)

      assert {:ok, _} = Gingko.Memory.open_project(project_id)

      assert_receive {:open_repo_opts, opts}
      assert %Mnemosyne.Config{extraction_profile: profile} = Keyword.fetch!(opts, :config)
      assert profile.name == :coding
      assert profile.overlays[:get_semantic] == "per-project instruction"
    end
  end

  test "start_session requires an already-open project" do
    project_id = "memory-test-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:error, %{code: :project_not_open, id: repo_id}} =
             Gingko.Memory.start_session(%{
               project_id: project_id,
               goal: "Remember OTP design choices",
               agent: "codex",
               thread_id: "thread-123"
             })

    assert repo_id == Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
  end

  test "append_step delegates to Mnemosyne.append_async/4" do
    Mimic.copy(Mnemosyne)

    expect(Mnemosyne, :append_async, fn session_id, observation, action ->
      assert session_id == "session-123"
      assert observation == "Observed something"
      assert action == "Did something"
      :ok
    end)

    assert {:ok, %{session_id: "session-123"}} =
             Gingko.Memory.append_step(%{
               session_id: "session-123",
               observation: "Observed something",
               action: "Did something"
             })
  end

  test "close_async delegates to Mnemosyne.close_async and returns :closing" do
    Mimic.copy(Mnemosyne)

    expect(Mnemosyne, :close_async, fn "session-123", callback ->
      assert is_function(callback, 1)
      :ok
    end)

    assert {:ok, %{session_id: "session-123", state: :closing}} =
             Gingko.Memory.close_async(%{session_id: "session-123"})
  end

  test "session write operations emit debug logs" do
    Mimic.copy(Mnemosyne)
    repo_id = Gingko.Memory.ProjectRegistry.resolve("project-123").repo_id
    previous_level = Logger.level()

    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    expect(Mnemosyne, :start_session, fn "Remember OTP design choices", [repo: ^repo_id] ->
      {:ok, "session-123"}
    end)

    expect(Mnemosyne, :append_async, fn "session-123", "Observed something", "Did something" ->
      :ok
    end)

    expect(Mnemosyne, :close_async, fn "session-123", _callback ->
      :ok
    end)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %{session_id: "session-123"}} =
                 Gingko.Memory.start_session(%{
                   project_id: "project-123",
                   goal: "Remember OTP design choices"
                 })

        assert {:ok, %{session_id: "session-123"}} =
                 Gingko.Memory.append_step(%{
                   session_id: "session-123",
                   observation: "Observed something",
                   action: "Did something"
                 })

        assert {:ok, %{session_id: "session-123", state: :closing}} =
                 Gingko.Memory.close_async(%{session_id: "session-123"})
      end)

    assert log =~ "Starting memory session for project_id=project-123 repo_id=#{repo_id}"
    assert log =~ "Queued async append for session_id=session-123"
    assert log =~ "Queued async close for session_id=session-123"
  end

  @tag capture_log: true
  test "session write flow succeeds end to end" do
    project_id = "memory-test-" <> Integer.to_string(System.unique_integer([:positive]))

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, &mock_chat/2)
    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, &mock_chat_structured/3)

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      if repo_id in Mnemosyne.list_repos() do
        :ok = Mnemosyne.close_repo(repo_id)
      end
    end)

    assert {:ok, _project} = Gingko.Memory.open_project(project_id)

    assert {:ok, session} =
             Gingko.Memory.start_session(%{
               project_id: project_id,
               goal: "Remember OTP design choices",
               agent: "codex",
               thread_id: "thread-123"
             })

    assert {:ok, _} =
             Gingko.Memory.append_step(%{
               session_id: session.session_id,
               observation: "Need serialized writes but cheap concurrent reads",
               action: "Chose Mnemosyne-backed repo with DETS persistence"
             })

    assert {:ok, %{state: :collecting}} = Gingko.Memory.session_state(session.session_id)

    assert {:ok, %{state: :closing}} =
             Gingko.Memory.close_async(%{session_id: session.session_id})
  end

  describe "mnemosyne memory appended telemetry bridge" do
    @event [:mnemosyne, :memory, :appended]

    setup do
      original = Application.get_env(:gingko, Gingko.Summaries.Config)
      Application.put_env(:gingko, Gingko.Summaries.Config, enabled: true)

      on_exit(fn ->
        if original do
          Application.put_env(:gingko, Gingko.Summaries.Config, original)
        else
          Application.delete_env(:gingko, Gingko.Summaries.Config)
        end
      end)

      :ok
    end

    @tag capture_log: true
    test "emits event with project_key, node.id, and linked_tags with memory_count when a changeset is applied" do
      project_id =
        "memory-bridge-" <> Integer.to_string(System.unique_integer([:positive]))

      on_exit(fn -> close_project_if_open(project_id) end)

      test_pid = self()
      handler_id = {__MODULE__, :bridge_test, System.unique_integer([:positive])}

      :ok =
        :telemetry.attach(
          handler_id,
          @event,
          fn _event, measurements, metadata, _ ->
            send(test_pid, {:mnemosyne_memory_appended, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _project} = Gingko.Memory.open_project(project_id)
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      semantic = %Mnemosyne.Graph.Node.Semantic{
        id: "sem-bridge-1",
        proposition: "Bridge emits memory appended",
        confidence: 0.9
      }

      tag_auth = %Mnemosyne.Graph.Node.Tag{id: "tag-auth-1", label: "Auth"}
      tag_graph = %Mnemosyne.Graph.Node.Tag{id: "tag-graph-1", label: "Graph"}

      changeset =
        Mnemosyne.Graph.Changeset.new()
        |> Mnemosyne.Graph.Changeset.add_node(semantic)
        |> Mnemosyne.Graph.Changeset.add_node(tag_auth)
        |> Mnemosyne.Graph.Changeset.add_node(tag_graph)
        |> Mnemosyne.Graph.Changeset.add_link(tag_auth.id, semantic.id, :membership)
        |> Mnemosyne.Graph.Changeset.add_link(tag_graph.id, semantic.id, :membership)

      :ok = Mnemosyne.apply_changeset(repo_id, changeset)

      assert_receive {:mnemosyne_memory_appended, _measurements, metadata}, 5_000

      assert %{project_key: ^project_id, node: %{id: node_id}, linked_tags: linked_tags} =
               metadata

      assert is_binary(metadata.project_key)
      assert is_binary(metadata.node.id)
      assert node_id == semantic.id
      assert is_list(linked_tags)
      assert length(linked_tags) == 2

      tag_ids = Enum.map(linked_tags, & &1.id) |> Enum.sort()
      assert tag_ids == Enum.sort([tag_auth.id, tag_graph.id])

      for tag <- linked_tags do
        assert %{id: tag_id, label: label, memory_count: memory_count} = tag
        assert is_binary(tag_id)
        assert is_binary(label)
        assert is_integer(memory_count) and memory_count >= 1
      end
    end
  end

  test "session write flow still succeeds when notifier raises" do
    project_id = "memory-notifier-" <> Integer.to_string(System.unique_integer([:positive]))

    Mimic.copy(Gingko.Memory.Notifier)
    stub(Gingko.Memory.Notifier, :notify, fn _repo_id, _event -> raise "notifier failed" end)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, &mock_chat/2)
    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, &mock_chat_structured/3)

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      if repo_id in Mnemosyne.list_repos() do
        :ok = Mnemosyne.close_repo(repo_id)
      end
    end)

    log =
      capture_log(fn ->
        assert {:ok, _project} = Gingko.Memory.open_project(project_id)

        assert {:ok, session} =
                 Gingko.Memory.start_session(%{
                   project_id: project_id,
                   goal: "Remember OTP design choices",
                   agent: "codex",
                   thread_id: "thread-123"
                 })

        assert {:ok, _} =
                 Gingko.Memory.append_step(%{
                   session_id: session.session_id,
                   observation: "Need serialized writes but cheap concurrent reads",
                   action: "Chose Mnemosyne-backed repo with DETS persistence"
                 })

        assert {:ok, %{state: :closing}} =
                 Gingko.Memory.close_async(%{session_id: session.session_id})
      end)

    assert log =~ "Notifier Gingko.Memory.Notifier failed: notifier failed"
  end

  describe "inspector_data/1" do
    setup do
      Mimic.copy(Mnemosyne)

      project_id = "memory-inspector-" <> Integer.to_string(System.unique_integer([:positive]))

      on_exit(fn ->
        close_project_if_open(project_id)
      end)

      {:ok, _project} = Gingko.Memory.open_project(project_id)

      %{project_id: project_id}
    end

    test "returns node map for an open project", %{project_id: project_id} do
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      node = %Semantic{id: "s1", proposition: "test fact", confidence: 0.8}

      stub(Mnemosyne, :get_graph, fn ^repo_id ->
        graph = Mnemosyne.Graph.new()
        Mnemosyne.Graph.put_node(graph, node)
      end)

      assert {:ok, node_map} = Gingko.Memory.inspector_data(project_id)
      assert Map.has_key?(node_map, "s1")
    end

    test "returns empty node map when graph is empty", %{project_id: project_id} do
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      stub(Mnemosyne, :get_graph, fn ^repo_id ->
        Mnemosyne.Graph.new()
      end)

      assert {:ok, node_map} = Gingko.Memory.inspector_data(project_id)
      assert node_map == %{}
    end

    test "returns error when get_graph raises", %{project_id: project_id} do
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      stub(Mnemosyne, :get_graph, fn ^repo_id ->
        raise RuntimeError, "graph store exploded"
      end)

      assert {:error, %{code: :inspector_data_failed, message: "graph store exploded"}} =
               Gingko.Memory.inspector_data(project_id)
    end
  end

  describe "memory read facade" do
    setup do
      Mimic.copy(Mnemosyne)

      project_id = "memory-read-" <> Integer.to_string(System.unique_integer([:positive]))

      on_exit(fn ->
        close_project_if_open(project_id)
      end)

      {:ok, _project} = Gingko.Memory.open_project(project_id)
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

      %{project_id: project_id, repo_id: repo_id}
    end

    test "list_projects returns registered Gingko projects", %{
      project_id: project_id,
      repo_id: repo_id
    } do
      assert %{projects: projects} = Gingko.Memory.list_projects()

      assert Enum.any?(projects, fn %{project_id: pid, repo_id: rid} ->
               pid == project_id and rid == repo_id
             end)
    end

    @tag :tmp_dir
    test "list_projects includes registered projects even when the repo is closed", %{
      tmp_dir: tmp_dir
    } do
      project_id = "memory-registered-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, _project} =
        Gingko.Projects.register_project(%{project_key: project_id, storage_root: tmp_dir})

      assert %{projects: projects} = Gingko.Memory.list_projects()

      assert Enum.any?(projects, fn %{project_id: pid} -> pid == project_id end)
    end

    test "recall extracts reasoned memory and touched_node_ids from RecallResult", %{
      project_id: project_id
    } do
      reasoned = %ReasonedMemory{semantic: "summary"}

      touched = [
        %TouchedNode{id: "sem-1", type: :semantic, score: 0.9, phase: :vector, hop: nil},
        %TouchedNode{id: "tag-1", type: :tag, score: 0.7, phase: :graph, hop: 1}
      ]

      recall_result = %RecallResult{reasoned: reasoned, touched_nodes: touched}

      stub(Mnemosyne, :recall, fn repo_id, query ->
        assert repo_id == Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
        assert query == "what is memory?"
        {:ok, recall_result}
      end)

      assert {:ok, result} =
               Gingko.Memory.recall(%{project_id: project_id, query: "what is memory?"})

      assert result.memory == %{episodic: nil, semantic: "summary", procedural: nil}
      assert result.touched_node_ids == ["sem-1", "tag-1"]
      assert result.query == "what is memory?"
      assert result.session_id == nil
    end

    test "recall with session forwards to recall_in_context", %{project_id: project_id} do
      reasoned = %ReasonedMemory{episodic: "context"}
      recall_result = %RecallResult{reasoned: reasoned, touched_nodes: []}

      {:ok, session} =
        Gingko.Memory.start_session(%{
          project_id: project_id,
          goal: "contextualize",
          agent: "codex",
          thread_id: "thread-1"
        })

      expect(Mnemosyne, :recall_in_context, fn repo_id, session_id, query ->
        assert repo_id == Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
        assert session_id == session.session_id
        assert query == "context query"
        {:ok, recall_result}
      end)

      assert {:ok, result} =
               Gingko.Memory.recall(%{
                 project_id: project_id,
                 query: "context query",
                 session_id: session.session_id
               })

      assert result.memory[:episodic] == "context"
      assert result.touched_node_ids == []
      assert result.session_id == session.session_id
    end

    test "recall returns project_not_open when repo is unopened" do
      assert {:error, %{code: :project_not_open}} =
               Gingko.Memory.recall(%{project_id: "missing-project", query: "query"})
    end

    test "get_node returns serialized node, metadata, and linked nodes", %{
      project_id: project_id,
      repo_id: repo_id
    } do
      tag = %Tag{id: "tag-1", label: "tag"}

      semantic = %Semantic{
        id: "sem-1",
        proposition: "fact",
        confidence: 0.5,
        links: %{
          membership: MapSet.new(["tag-1"]),
          hierarchical: MapSet.new([]),
          provenance: MapSet.new([]),
          sibling: MapSet.new([])
        }
      }

      stub(Mnemosyne, :get_node, fn ^repo_id, "sem-1" -> {:ok, semantic} end)

      stub(Mnemosyne, :get_metadata, fn ^repo_id, ["sem-1"] ->
        {:ok, %{"sem-1" => NodeMetadata.new(access_count: 7)}}
      end)

      stub(Mnemosyne, :get_linked_nodes, fn ^repo_id, ["tag-1"] -> {:ok, [tag]} end)

      assert {:ok, result} =
               Gingko.Memory.get_node(%{project_id: project_id, node_id: "sem-1"})

      assert result.node.id == "sem-1"
      assert result.metadata.access_count == 7
      assert Enum.any?(result.linked_nodes, &(&1.id == "tag-1"))
    end

    test "get_node returns nil when node missing", %{project_id: project_id} do
      assert {:ok, %{node: nil, metadata: nil, linked_nodes: []}} =
               Gingko.Memory.get_node(%{project_id: project_id, node_id: "unknown"})
    end
  end

  describe "project_monitor_snapshot/1 degraded path" do
    test "returns degraded: true when Projects.list_sessions raises Ecto.NoResultsError" do
      Mimic.copy(Gingko.Projects)

      stub(Gingko.Projects, :list_sessions, fn _project_id, _opts ->
        raise Ecto.NoResultsError, queryable: Gingko.Projects.Project
      end)

      project_id = "degraded-#{System.unique_integer([:positive])}"

      assert %{
               project_id: ^project_id,
               degraded: true,
               active_sessions: [],
               counters: %{active_sessions: 0}
             } = Gingko.Memory.project_monitor_snapshot(project_id)
    end

    @tag :tmp_dir
    test "returns degraded: false on the happy path for a registered project", %{tmp_dir: tmp_dir} do
      project_id = "happy-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Gingko.Projects.register_project(%{project_key: project_id, storage_root: tmp_dir})

      assert %{project_id: ^project_id, degraded: false} =
               Gingko.Memory.project_monitor_snapshot(project_id)
    end
  end

  describe "list_projects_with_stats/0" do
    setup do
      Gingko.Repo.delete_all(Gingko.Projects.Session)
      Gingko.Repo.delete_all(Gingko.Projects.ProjectMemory)
      Gingko.Repo.delete_all(Gingko.Projects.Project)
      :ok
    end

    test "returns an empty list when no projects are registered" do
      assert %{projects: []} = Gingko.Memory.list_projects_with_stats()
    end

    @tag :tmp_dir
    test "returns stats for a single registered project", %{tmp_dir: tmp_dir} do
      project_key = "stats-single-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Gingko.Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      assert %{projects: [entry]} = Gingko.Memory.list_projects_with_stats()

      assert entry.project_id == project_key
      assert entry.display_name == project_key
      assert is_integer(entry.total_nodes)
      assert is_integer(entry.total_edges)
      assert is_integer(entry.orphan_count)
      assert entry.active_sessions == 0
      assert Map.has_key?(entry, :avg_confidence)
      assert Map.has_key?(entry, :last_activity_at)
    end

    @tag :tmp_dir
    test "returns stats for each of two registered projects", %{tmp_dir: tmp_dir} do
      project_a = "stats-a-#{System.unique_integer([:positive])}"
      project_b = "stats-b-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Gingko.Projects.register_project(%{project_key: project_a, storage_root: tmp_dir})

      {:ok, _} =
        Gingko.Projects.register_project(%{project_key: project_b, storage_root: tmp_dir})

      %{projects: entries} = Gingko.Memory.list_projects_with_stats()

      ids = Enum.map(entries, & &1.project_id)
      assert Enum.sort(ids) == Enum.sort([project_a, project_b])

      Enum.each(entries, fn entry ->
        snapshot = Gingko.Memory.project_monitor_snapshot(entry.project_id)
        assert entry.total_nodes == snapshot.quality.total_nodes
        assert entry.total_edges == snapshot.quality.total_edges
        assert entry.orphan_count == snapshot.quality.orphan_count
        assert entry.avg_confidence == snapshot.quality.avg_confidence
        assert entry.active_sessions == snapshot.counters.active_sessions
      end)
    end

    @tag :tmp_dir
    test "counts active sessions and surfaces last_activity_at from active sessions", %{
      tmp_dir: tmp_dir
    } do
      project_key = "stats-active-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Gingko.Projects.register_project(%{project_key: project_key, storage_root: tmp_dir})

      session_id = "session-#{System.unique_integer([:positive])}"

      {:ok, session} =
        Gingko.Projects.create_session(%{project_key: project_key, session_id: session_id})

      assert %{projects: [entry]} = Gingko.Memory.list_projects_with_stats()

      assert entry.active_sessions == 1
      assert entry.last_activity_at == session.updated_at
    end
  end

  describe "projects stats pubsub" do
    test "broadcast_project_stats_changed/1 notifies subscribers" do
      :ok = Gingko.Memory.subscribe_projects_stats()

      on_exit(fn ->
        Phoenix.PubSub.unsubscribe(Gingko.PubSub, Gingko.Memory.projects_stats_topic())
      end)

      Gingko.Memory.broadcast_project_stats_changed("some-project")

      assert_receive {:project_stats_changed, "some-project"}, 500
    end
  end

  defp mock_chat(messages, _opts) do
    prompt = system_prompt(messages)

    content =
      cond do
        String.contains?(prompt, "identify the specific sub-goal") ->
          "Persist project memory safely"

        String.contains?(prompt, "rate how well this action serves the sub-goal") ->
          "0.9"

        String.contains?(prompt, "provide a concise summary of the current environment state") ->
          "The project now has an open repo and is appending memory-relevant steps."

        true ->
          "mock response"
      end

    {:ok, %Mnemosyne.LLM.Response{content: content, model: "mock:test", usage: %{}}}
  end

  defp mock_chat_structured(messages, _schema, _opts) do
    prompt = system_prompt(messages)

    content =
      cond do
        String.contains?(prompt, "extracting factual knowledge from agent experiences") ->
          %{
            facts: [
              %{
                proposition: "Project memory is stored in a Mnemosyne-backed repo.",
                concepts: ["project memory", "mnemosyne"]
              }
            ]
          }

        String.contains?(prompt, "extracting actionable instructions from agent experiences") ->
          %{
            instructions: [
              %{
                intent: "Persist project memory",
                condition: "When a session contains memory-worthy steps",
                instruction: "Close the session and commit it through Mnemosyne.",
                expected_outcome: "The session becomes durable project memory."
              }
            ]
          }

        String.contains?(prompt, "evaluating prescription quality") ->
          %{
            scores: [
              %{index: 0, return_score: 0.85}
            ]
          }

        true ->
          %{}
      end

    {:ok, %Mnemosyne.LLM.Response{content: content, model: "mock:test", usage: %{}}}
  end

  defp system_prompt(messages) do
    Enum.find_value(messages, "", fn
      %{role: :system, content: content} -> content
      _ -> nil
    end)
  end

  defp close_project_if_open(project_id) do
    repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
    if repo_id in Mnemosyne.list_repos(), do: :ok = Mnemosyne.close_repo(repo_id)
  end
end
