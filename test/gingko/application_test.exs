defmodule Gingko.ApplicationTest do
  use ExUnit.Case, async: false

  alias Gingko.Projects
  alias Gingko.Settings
  alias Mnemosyne.MemoryStore

  test "mnemosyne supervisor is started" do
    assert Process.whereis(Mnemosyne.Supervisor)
  end

  test "application supervises the metadata repo" do
    child_ids =
      Gingko.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    assert Gingko.Repo in child_ids
    assert Gingko.Repo in Application.get_env(:gingko, :ecto_repos, [])
  end

  test "refresh_runtime_children/0 reloads mnemosyne defaults and clears stale open repos" do
    previous_settings = Application.get_env(:gingko, :settings)
    previous_memory = Application.get_env(:gingko, Gingko.Memory)

    on_exit(fn ->
      restore_env(:gingko, :settings, previous_settings)
      restore_env(:gingko, Gingko.Memory, previous_memory)
      :ok = Gingko.Application.refresh_runtime_children()
    end)

    Application.put_env(
      :gingko,
      Gingko.Memory,
      storage_root: "/tmp/gingko-memory",
      mnemosyne_config: %{
        llm: %{model: "openai:gpt-4o-mini", opts: %{}},
        embedding: %{model: "openai:text-embedding-3-small", opts: %{}}
      },
      llm_adapter: Gingko.TestSupport.Mnemosyne.MockLLM,
      embedding_adapter: Gingko.TestSupport.Mnemosyne.MockEmbedding
    )

    Application.delete_env(:gingko, :settings)
    :ok = Gingko.Application.refresh_runtime_children()

    repo_id = "runtime-refresh-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             Mnemosyne.open_repo(
               repo_id,
               backend: {Mnemosyne.GraphBackends.InMemory, persistence: nil}
             )

    assert repo_id in Mnemosyne.list_repos()

    settings = %Settings{
      home: "/tmp/gingko-home",
      paths: %{memory: "memory"},
      llm: %{provider: "openrouter", model: "google/gemini-3-flash-preview"},
      embeddings: %{provider: "bumblebee", model: "intfloat/e5-base-v2"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        intent_merge_threshold: 0.8,
        intent_identity_threshold: 0.95,
        refinement_threshold: 0.6,
        refinement_budget: 1,
        plateau_delta: 0.05,
        extraction_profile: "none",
        consolidation_threshold: 0.85,
        decay_threshold: 0.1,
        auto_commit: true,
        flush_timeout_ms: 120_000,
        session_timeout_ms: 600_000,
        trace_verbosity: "summary"
      },
      episodic_validation: %{
        validation_threshold: 0.3,
        orphan_penalty: 0.3,
        weak_grounding_penalty: 0.1
      },
      summaries: %{
        enabled: false,
        regen_debounce_seconds: 60,
        summary_memory_count: 200,
        session_primer_recent_count: 15
      },
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    Application.put_env(:gingko, :settings, settings)

    Application.put_env(
      :gingko,
      Gingko.Memory,
      storage_root: "/tmp/gingko-home/memory",
      mnemosyne_config: %{
        llm: %{model: "openrouter:google/gemini-3-flash-preview", opts: %{}},
        embedding: %{
          model: "intfloat/e5-base-v2",
          opts: %{
            serving: Gingko.Embeddings.BumblebeeServing.name(),
            model: "intfloat/e5-base-v2"
          }
        }
      },
      llm_adapter: Mnemosyne.Adapters.SycophantLLM,
      embedding_adapter: Gingko.Embeddings.LazyBumblebeeEmbedding
    )

    :ok = Gingko.Application.refresh_runtime_children()

    refute repo_id in Mnemosyne.list_repos()

    defaults = Mnemosyne.Supervisor.get_defaults()

    child_ids =
      Gingko.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    assert defaults.config.llm.model == "openrouter:google/gemini-3-flash-preview"
    assert defaults.config.embedding.model == "intfloat/e5-base-v2"
    assert defaults.embedding == Gingko.Embeddings.LazyBumblebeeEmbedding
    assert Gingko.Embeddings.BumblebeeServing in child_ids

    assert {:ok, _pid} =
             Mnemosyne.open_repo(
               repo_id,
               backend: {Mnemosyne.GraphBackends.InMemory, persistence: nil}
             )

    [{store_pid, _value}] = Registry.lookup(Mnemosyne.Supervisor.RepoRegistry, repo_id)
    repo_defaults = MemoryStore.get_session_defaults(store_pid)

    assert repo_defaults.config.llm.model == "openrouter:google/gemini-3-flash-preview"
    assert repo_defaults.embedding == Gingko.Embeddings.LazyBumblebeeEmbedding
  end

  @tag :tmp_dir
  test "refresh_runtime_children/0 reopens registered project repos", %{tmp_dir: tmp_dir} do
    project_id = "reopen-project-" <> Integer.to_string(System.unique_integer([:positive]))
    repo_id = Gingko.Memory.ProjectRegistry.repo_id(project_id)

    on_exit(fn ->
      if repo_id in Mnemosyne.list_repos() do
        :ok = Mnemosyne.close_repo(repo_id)
      end
    end)

    assert {:ok, _project} =
             Projects.register_project(%{project_key: project_id, storage_root: tmp_dir})

    assert {:ok, %{already_open?: false}} = Gingko.Memory.open_project(project_id)
    assert repo_id in Mnemosyne.list_repos()

    assert :ok = Mnemosyne.close_repo(repo_id)

    eventually(fn ->
      refute repo_id in Mnemosyne.list_repos()
    end)

    assert :ok = Gingko.Application.refresh_runtime_children()

    assert repo_id in Mnemosyne.list_repos()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp eventually(fun, retries \\ 50)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, retries - 1)
  end
end
