defmodule Gingko.SettingsTest do
  use ExUnit.Case, async: true

  alias Gingko.Settings

  @default_mnemosyne %{
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
  }

  @default_episodic_validation %{
    validation_threshold: 0.3,
    orphan_penalty: 0.3,
    weak_grounding_penalty: 0.1
  }

  @default_summaries %{
    enabled: true,
    hot_tags_k: 15,
    cluster_regen_memory_threshold: 10,
    cluster_regen_idle_seconds: 1800,
    principal_regen_debounce_seconds: 60,
    session_primer_recent_count: 15,
    chunk_chars: 512_000,
    max_chunks: 8,
    parallelism: 4,
    chunk_timeout_ms: 60_000
  }

  test "home/1 falls back to ~/.gingko when GINGKO_HOME is not set" do
    env = fn
      "GINGKO_HOME" -> nil
      _ -> nil
    end

    assert Settings.home(env: env) == Path.expand("~/.gingko")
  end

  @tag :tmp_dir
  test "home/1 uses GINGKO_HOME when set", %{tmp_dir: tmp_dir} do
    env = fn
      "GINGKO_HOME" -> tmp_dir
      _ -> nil
    end

    assert Settings.home(env: env) == tmp_dir
  end

  @tag :tmp_dir
  test "ensure_defaults!/1 creates config.toml and memory directory", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)
    memory_path = Path.join(tmp_dir, "memory")

    assert config_path == Path.join(tmp_dir, "config.toml")
    assert File.exists?(config_path)
    assert File.dir?(memory_path)
  end

  @tag :tmp_dir
  test "load/1 reports unsupported model as readiness issue", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "openai"
      model = "nonexistent-model"

      [embeddings]
      provider = "openai"
      model = "text-embedding-3-small"

      [server]
      host = "127.0.0.1"
      port = 4000
      """
    )

    llm_resolver = fn _ -> {:error, :unknown_model} end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    refute settings.ready?

    assert Enum.any?(settings.issues, fn issue ->
             issue.path == "llm.model" and
               String.contains?(issue.message, "unsupported model")
           end)
  end

  @tag :tmp_dir
  test "load/1 accepts mixed providers for llm and embeddings", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "anthropic"
      model = "claude-sonnet-4"

      [embeddings]
      provider = "openai"
      model = "text-embedding-3-small"

      [server]
      host = "127.0.0.1"
      port = 4000
      """
    )

    llm_resolver = fn
      "anthropic:claude-sonnet-4" -> {:ok, %{provider: :anthropic}}
      _ -> {:error, :unknown_model}
    end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    assert settings.ready?
    assert settings.llm.provider == "anthropic"
    assert settings.embeddings.provider == "openai"
  end

  @tag :tmp_dir
  test "load/1 accepts providers supported by the configured model resolvers", %{
    tmp_dir: tmp_dir
  } do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "openrouter"
      model = "gpt-4o-mini"

      [embeddings]
      provider = "openai"
      model = "text-embedding-3-small"

      [server]
      host = "127.0.0.1"
      port = 4000
      """
    )

    llm_resolver = fn
      "openrouter:gpt-4o-mini" -> {:ok, %{provider: :openrouter}}
      _ -> {:error, :unknown_model}
    end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    assert settings.ready?
    assert settings.llm.provider == "openrouter"
  end

  @tag :tmp_dir
  test "memory_root/1 resolves memory path relative to home", %{tmp_dir: tmp_dir} do
    settings = %Settings{
      home: tmp_dir,
      paths: %{memory: "state/memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: @default_mnemosyne,
      episodic_validation: @default_episodic_validation,
      summaries: @default_summaries,
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    assert Settings.memory_root(settings) == Path.join(tmp_dir, "state/memory")
  end

  @tag :tmp_dir
  test "save/2 persists settings and load/1 reads them back", %{tmp_dir: tmp_dir} do
    attrs = %{
      paths: %{memory: "custom-memory"},
      llm: %{provider: "anthropic", model: "claude-sonnet-4"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "0.0.0.0", port: 4010}
    }

    llm_resolver = fn
      "anthropic:claude-sonnet-4" -> {:ok, %{provider: :anthropic}}
      _ -> {:error, :unknown_model}
    end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    assert {:ok, saved} =
             Settings.save(
               attrs,
               home: tmp_dir,
               llm_resolver: llm_resolver,
               embedding_resolver: embedding_resolver
             )

    assert saved.paths.memory == "custom-memory"

    loaded =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    assert loaded.paths.memory == "custom-memory"
    assert loaded.server.host == "0.0.0.0"
    assert loaded.server.port == 4010
    assert loaded.llm.provider == "anthropic"
    assert loaded.embeddings.provider == "openai"
  end

  @tag :tmp_dir
  test "mnemosyne_runtime/1 returns Gingko.Memory-compatible shape", %{tmp_dir: tmp_dir} do
    settings = %Settings{
      home: tmp_dir,
      paths: %{memory: "memory"},
      llm: %{provider: "anthropic", model: "claude-sonnet-4"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: @default_mnemosyne,
      episodic_validation: @default_episodic_validation,
      summaries: @default_summaries,
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    runtime = Settings.mnemosyne_runtime(settings)

    assert runtime.storage_root == Path.join(tmp_dir, "memory")
    assert runtime.llm_adapter == Mnemosyne.Adapters.SycophantLLM
    assert runtime.embedding_adapter == Mnemosyne.Adapters.SycophantEmbedding
    assert runtime.mnemosyne_config.llm.model == "anthropic:claude-sonnet-4"
    assert runtime.mnemosyne_config.embedding.model == "openai:text-embedding-3-small"
    assert runtime.mnemosyne_config.intent_merge_threshold == 0.8
    assert runtime.mnemosyne_config.intent_identity_threshold == 0.95
    assert runtime.mnemosyne_config.refinement_threshold == 0.6
    assert runtime.mnemosyne_config.session.auto_commit == true
    assert runtime.mnemosyne_config.session.flush_timeout_ms == 120_000
    assert runtime.mnemosyne_config.session.session_timeout_ms == 600_000
    assert runtime.mnemosyne_config.trace_verbosity == :summary
    assert runtime.mnemosyne_config.refinement_budget == 1
    assert runtime.mnemosyne_config.plateau_delta == 0.05
    refute Map.has_key?(runtime.mnemosyne_config, :extraction_profile)
    assert runtime.mnemosyne_config.episodic_validation.validation_threshold == 0.3
    assert runtime.mnemosyne_config.episodic_validation.orphan_penalty == 0.3
    assert runtime.mnemosyne_config.episodic_validation.weak_grounding_penalty == 0.1
  end

  @tag :tmp_dir
  test "mnemosyne_runtime/1 resolves coding extraction profile", %{tmp_dir: tmp_dir} do
    settings = %Settings{
      home: tmp_dir,
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{@default_mnemosyne | extraction_profile: "coding"},
      episodic_validation: @default_episodic_validation,
      summaries: @default_summaries,
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    runtime = Settings.mnemosyne_runtime(settings)

    assert %Mnemosyne.ExtractionProfile{name: :coding} =
             runtime.mnemosyne_config.extraction_profile
  end

  describe "project_mnemosyne_config/2" do
    @describetag :tmp_dir

    test "returns a Mnemosyne.Config struct with global profile for empty overlay", %{
      tmp_dir: tmp_dir
    } do
      settings = build_settings(tmp_dir, extraction_profile: "coding")

      config =
        Settings.project_mnemosyne_config(settings, %Gingko.Projects.ExtractionOverlay{})

      assert %Mnemosyne.Config{} = config
      assert %Mnemosyne.ExtractionProfile{name: :coding} = config.extraction_profile
    end

    test "merges project step override on top of the global profile", %{tmp_dir: tmp_dir} do
      settings = build_settings(tmp_dir, extraction_profile: "coding")

      overlay = %Gingko.Projects.ExtractionOverlay{
        base: "inherit_global",
        steps: %{get_semantic: "custom text"}
      }

      config = Settings.project_mnemosyne_config(settings, overlay)

      assert config.extraction_profile.overlays[:get_semantic] == "custom text"

      assert config.extraction_profile.overlays[:get_procedural] ==
               Mnemosyne.ExtractionProfile.coding().overlays[:get_procedural]
    end

    test "none base without overlays clears the extraction profile", %{tmp_dir: tmp_dir} do
      settings = build_settings(tmp_dir, extraction_profile: "coding")

      overlay = %Gingko.Projects.ExtractionOverlay{base: "none"}

      config = Settings.project_mnemosyne_config(settings, overlay)
      assert config.extraction_profile == nil
    end

    test "project base overrides the global profile", %{tmp_dir: tmp_dir} do
      settings = build_settings(tmp_dir, extraction_profile: "coding")

      overlay = %Gingko.Projects.ExtractionOverlay{base: "research"}
      config = Settings.project_mnemosyne_config(settings, overlay)

      assert config.extraction_profile.name == :research
    end
  end

  describe "global_extraction_profile/1" do
    test "returns known profiles" do
      assert Settings.global_extraction_profile("coding").name == :coding
      assert Settings.global_extraction_profile("research").name == :research
      assert Settings.global_extraction_profile("customer_support").name == :customer_support
    end

    test "returns nil for none or unknown" do
      assert Settings.global_extraction_profile("none") == nil
      assert Settings.global_extraction_profile(nil) == nil
      assert Settings.global_extraction_profile("bogus") == nil
    end
  end

  defp build_settings(tmp_dir, opts) do
    %Settings{
      home: tmp_dir,
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        @default_mnemosyne
        | extraction_profile: Keyword.get(opts, :extraction_profile, "none")
      },
      episodic_validation: @default_episodic_validation,
      summaries: @default_summaries,
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }
  end

  @tag :tmp_dir
  test "maintenance_opts/1 exposes consolidation and decay thresholds", %{tmp_dir: tmp_dir} do
    settings = %Settings{
      home: tmp_dir,
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        @default_mnemosyne
        | consolidation_threshold: 0.9,
          decay_threshold: 0.2
      },
      episodic_validation: @default_episodic_validation,
      summaries: @default_summaries,
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    assert Settings.maintenance_opts(settings) == [
             consolidation_threshold: 0.9,
             decay_threshold: 0.2
           ]
  end

  @tag :tmp_dir
  test "mnemosyne_runtime/1 passes custom threshold values", %{tmp_dir: tmp_dir} do
    settings = %Settings{
      home: tmp_dir,
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        @default_mnemosyne
        | intent_merge_threshold: 0.7,
          refinement_threshold: 0.5,
          trace_verbosity: "detailed"
      },
      episodic_validation: @default_episodic_validation,
      summaries: @default_summaries,
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    runtime = Settings.mnemosyne_runtime(settings)

    assert runtime.mnemosyne_config.intent_merge_threshold == 0.7
    assert runtime.mnemosyne_config.refinement_threshold == 0.5
    assert runtime.mnemosyne_config.trace_verbosity == :detailed
  end

  test "provider options are derived from the provider catalog" do
    providers_source = fn -> [:anthropic, :openai, :openrouter, :ollama] end

    models_source = fn
      :anthropic -> [%{modalities: %{output: [:text]}}]
      :openai -> [%{modalities: %{output: [:text, :embedding]}}]
      :openrouter -> [%{modalities: %{output: [:text]}}]
      :ollama -> []
    end

    assert Settings.llm_provider_options(
             providers_source: providers_source,
             models_source: models_source
           ) == ["anthropic", "openai", "openrouter"]

    assert Settings.embedding_provider_options(
             providers_source: providers_source,
             models_source: models_source
           ) == ["bumblebee", "openai"]
  end

  test "model_options/3 lists LLM models for a provider, sorted, excluding embeddings" do
    models_source = fn
      :openai ->
        [
          %{id: "gpt-4o", modalities: %{output: [:text]}},
          %{id: "gpt-4o-mini", modalities: %{output: [:text]}},
          %{id: "text-embedding-3-small", modalities: %{output: [:embedding]}}
        ]

      _ ->
        []
    end

    assert Settings.model_options("openai", :llm, models_source: models_source) ==
             ["gpt-4o", "gpt-4o-mini"]

    assert Settings.model_options("openai", :embedding, models_source: models_source) ==
             ["text-embedding-3-small"]
  end

  test "model_options/3 handles empty/nil providers and bumblebee" do
    assert Settings.model_options(nil, :llm) == []
    assert Settings.model_options("", :embedding) == []
    assert Settings.model_options("bumblebee", :embedding) == ["intfloat/e5-base-v2"]
    assert Settings.model_options("bumblebee", :llm) == []
  end

  @tag :tmp_dir
  test "load/1 treats bumblebee embeddings as ready without an API key", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "openai"
      model = "gpt-4o-mini"

      [embeddings]
      provider = "bumblebee"
      model = "intfloat/e5-base-v2"

      [server]
      host = "127.0.0.1"
      port = 4000
      """
    )

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings = Settings.load(home: tmp_dir, llm_resolver: llm_resolver)

    assert settings.ready?
    assert settings.embeddings.provider == "bumblebee"
    assert settings.embeddings.model == "intfloat/e5-base-v2"
  end

  @tag :tmp_dir
  test "load/1 trims surrounding whitespace from string settings values", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = " memory "

      [llm]
      provider = " openai "
      model = " gpt-4o-mini "

      [embeddings]
      provider = " bumblebee "
      model = " intfloat/e5-base-v2 "

      [server]
      host = " 127.0.0.1 "
      port = 4000
      """
    )

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings = Settings.load(home: tmp_dir, llm_resolver: llm_resolver)

    assert settings.ready?
    assert settings.paths.memory == "memory"
    assert settings.llm.provider == "openai"
    assert settings.llm.model == "gpt-4o-mini"
    assert settings.embeddings.provider == "bumblebee"
    assert settings.embeddings.model == "intfloat/e5-base-v2"
    assert settings.server.host == "127.0.0.1"
  end

  @tag :tmp_dir
  test "save/2 defaults the bumblebee embedding model when left blank", %{tmp_dir: tmp_dir} do
    attrs = %{
      paths: %{memory: "custom-memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "bumblebee", model: ""},
      server: %{host: "0.0.0.0", port: 4010}
    }

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    assert {:ok, settings} =
             Settings.save(attrs, home: tmp_dir, llm_resolver: llm_resolver)

    assert settings.ready?
    assert settings.embeddings.model == "intfloat/e5-base-v2"
  end

  @tag :tmp_dir
  test "mnemosyne_runtime/1 uses the bumblebee embedding adapter when configured", %{
    tmp_dir: tmp_dir
  } do
    settings = %Settings{
      home: tmp_dir,
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "bumblebee", model: "intfloat/e5-base-v2"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: @default_mnemosyne,
      episodic_validation: @default_episodic_validation,
      summaries: @default_summaries,
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    runtime = Settings.mnemosyne_runtime(settings)

    assert runtime.embedding_adapter == Gingko.Embeddings.LazyBumblebeeEmbedding
    assert runtime.mnemosyne_config.embedding.model == "intfloat/e5-base-v2"

    assert runtime.mnemosyne_config.embedding.opts == %{
             serving: Gingko.Embeddings.BumblebeeServing.name(),
             model: "intfloat/e5-base-v2"
           }
  end

  test "embedding provider options include bumblebee" do
    providers_source = fn -> [:openai] end

    models_source = fn
      :openai -> [%{modalities: %{output: [:text, :embedding]}}]
    end

    assert Settings.embedding_provider_options(
             providers_source: providers_source,
             models_source: models_source
           ) == ["bumblebee", "openai"]
  end

  @tag :tmp_dir
  test "load/1 reads mnemosyne config from toml", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "openai"
      model = "gpt-4o-mini"

      [embeddings]
      provider = "bumblebee"
      model = "intfloat/e5-base-v2"

      [server]
      host = "127.0.0.1"
      port = 4000

      [mnemosyne]
      intent_merge_threshold = 0.7
      intent_identity_threshold = 0.9
      refinement_threshold = 0.5
      auto_commit = false
      flush_timeout_ms = 60000
      session_timeout_ms = 300000
      trace_verbosity = "detailed"
      """
    )

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings = Settings.load(home: tmp_dir, llm_resolver: llm_resolver)

    assert settings.ready?
    assert settings.mnemosyne.intent_merge_threshold == 0.7
    assert settings.mnemosyne.intent_identity_threshold == 0.9
    assert settings.mnemosyne.refinement_threshold == 0.5
    assert settings.mnemosyne.auto_commit == false
    assert settings.mnemosyne.flush_timeout_ms == 60_000
    assert settings.mnemosyne.session_timeout_ms == 300_000
    assert settings.mnemosyne.trace_verbosity == "detailed"
  end

  @tag :tmp_dir
  test "load/1 populates summaries struct field from [summaries] section", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "openai"
      model = "gpt-4o-mini"

      [embeddings]
      provider = "bumblebee"
      model = "intfloat/e5-base-v2"

      [server]
      host = "127.0.0.1"
      port = 4000

      [summaries]
      enabled = true
      hot_tags_k = 20
      cluster_regen_memory_threshold = 5
      cluster_regen_idle_seconds = 600
      principal_regen_debounce_seconds = 90
      session_primer_recent_count = 8
      """
    )

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings = Settings.load(home: tmp_dir, llm_resolver: llm_resolver)

    assert settings.ready?
    assert settings.summaries.enabled == true
    assert settings.summaries.hot_tags_k == 20
    assert settings.summaries.cluster_regen_memory_threshold == 5
    assert settings.summaries.cluster_regen_idle_seconds == 600
    assert settings.summaries.principal_regen_debounce_seconds == 90
    assert settings.summaries.session_primer_recent_count == 8
  end

  @tag :tmp_dir
  test "load/1 falls back to default summaries values when [summaries] is absent", %{
    tmp_dir: tmp_dir
  } do
    _config_path = Settings.ensure_defaults!(home: tmp_dir)

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    assert settings.ready?
    assert settings.summaries.enabled == true
    assert settings.summaries.hot_tags_k == 15
    assert settings.summaries.cluster_regen_memory_threshold == 10
    assert settings.summaries.cluster_regen_idle_seconds == 1800
    assert settings.summaries.principal_regen_debounce_seconds == 60
    assert settings.summaries.session_primer_recent_count == 15
  end

  @tag :tmp_dir
  test "load/1 does not write Gingko.Summaries.Config env (pure loader)", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "openai"
      model = "gpt-4o-mini"

      [embeddings]
      provider = "bumblebee"
      model = "intfloat/e5-base-v2"

      [server]
      host = "127.0.0.1"
      port = 4000

      [summaries]
      enabled = true
      hot_tags_k = 42
      """
    )

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    original = Application.get_env(:gingko, Gingko.Summaries.Config)
    Application.delete_env(:gingko, Gingko.Summaries.Config)

    try do
      _settings = Settings.load(home: tmp_dir, llm_resolver: llm_resolver)

      assert Application.get_env(:gingko, Gingko.Summaries.Config) == nil
    after
      if original do
        Application.put_env(:gingko, Gingko.Summaries.Config, original)
      else
        Application.delete_env(:gingko, Gingko.Summaries.Config)
      end
    end
  end

  @tag :tmp_dir
  test "summaries_env/1 produces a keyword list matching the struct", %{tmp_dir: tmp_dir} do
    settings = %Settings{
      home: tmp_dir,
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: @default_mnemosyne,
      episodic_validation: @default_episodic_validation,
      summaries: %{
        enabled: true,
        hot_tags_k: 20,
        cluster_regen_memory_threshold: 5,
        cluster_regen_idle_seconds: 600,
        principal_regen_debounce_seconds: 90,
        session_primer_recent_count: 8,
        chunk_chars: 200_000,
        max_chunks: 4,
        parallelism: 2,
        chunk_timeout_ms: 45_000
      },
      overrides: %{},
      value_function: %{},
      issues: [],
      ready?: true
    }

    env = Settings.summaries_env(settings)

    assert env[:enabled] == true
    assert env[:hot_tags_k] == 20
    assert env[:cluster_regen_memory_threshold] == 5
    assert env[:cluster_regen_idle_seconds] == 600
    assert env[:principal_regen_debounce_seconds] == 90
    assert env[:session_primer_recent_count] == 8
    assert env[:chunk_chars] == 200_000
    assert env[:max_chunks] == 4
    assert env[:parallelism] == 2
    assert env[:chunk_timeout_ms] == 45_000
  end

  @tag :tmp_dir
  test "save/2 persists mnemosyne config and reads it back", %{tmp_dir: tmp_dir} do
    attrs = %{
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "bumblebee", model: "intfloat/e5-base-v2"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        intent_merge_threshold: 0.7,
        refinement_threshold: 0.5,
        intent_identity_threshold: 0.9,
        auto_commit: false,
        flush_timeout_ms: 60_000,
        session_timeout_ms: 300_000,
        trace_verbosity: "detailed"
      }
    }

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    assert {:ok, saved} = Settings.save(attrs, home: tmp_dir, llm_resolver: llm_resolver)

    assert saved.mnemosyne.intent_merge_threshold == 0.7
    assert saved.mnemosyne.auto_commit == false
    assert saved.mnemosyne.trace_verbosity == "detailed"

    loaded = Settings.load(home: tmp_dir, llm_resolver: llm_resolver)

    assert loaded.mnemosyne.intent_merge_threshold == 0.7
    assert loaded.mnemosyne.auto_commit == false
    assert loaded.mnemosyne.trace_verbosity == "detailed"
  end

  @tag :tmp_dir
  test "load/1 defaults the newly exposed Mnemosyne knobs when config.toml lacks them", %{
    tmp_dir: tmp_dir
  } do
    _ = Settings.ensure_defaults!(home: tmp_dir)

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    assert settings.mnemosyne.refinement_budget == 1
    assert settings.mnemosyne.plateau_delta == 0.05
    assert settings.mnemosyne.extraction_profile == "none"
    assert settings.mnemosyne.consolidation_threshold == 0.85
    assert settings.mnemosyne.decay_threshold == 0.1
    assert settings.episodic_validation.validation_threshold == 0.3
    assert settings.episodic_validation.orphan_penalty == 0.3
    assert settings.episodic_validation.weak_grounding_penalty == 0.1
  end

  @tag :tmp_dir
  test "save/2 round-trips new Mnemosyne and episodic_validation knobs", %{tmp_dir: tmp_dir} do
    attrs = %{
      paths: %{memory: "memory"},
      llm: %{provider: "openai", model: "gpt-4o-mini"},
      embeddings: %{provider: "openai", model: "text-embedding-3-small"},
      server: %{host: "127.0.0.1", port: 4000},
      mnemosyne: %{
        intent_merge_threshold: 0.8,
        intent_identity_threshold: 0.95,
        refinement_threshold: 0.6,
        refinement_budget: 3,
        plateau_delta: 0.1,
        extraction_profile: "coding",
        consolidation_threshold: 0.9,
        decay_threshold: 0.2,
        auto_commit: true,
        flush_timeout_ms: 120_000,
        session_timeout_ms: 600_000,
        trace_verbosity: "summary"
      },
      episodic_validation: %{
        validation_threshold: 0.5,
        orphan_penalty: 0.4,
        weak_grounding_penalty: 0.2
      }
    }

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    assert {:ok, saved} =
             Settings.save(attrs,
               home: tmp_dir,
               llm_resolver: llm_resolver,
               embedding_resolver: embedding_resolver
             )

    assert saved.mnemosyne.refinement_budget == 3
    assert saved.mnemosyne.plateau_delta == 0.1
    assert saved.mnemosyne.extraction_profile == "coding"
    assert saved.mnemosyne.consolidation_threshold == 0.9
    assert saved.mnemosyne.decay_threshold == 0.2
    assert saved.episodic_validation.validation_threshold == 0.5
    assert saved.episodic_validation.orphan_penalty == 0.4
    assert saved.episodic_validation.weak_grounding_penalty == 0.2

    loaded =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    assert loaded.mnemosyne.refinement_budget == 3
    assert loaded.mnemosyne.extraction_profile == "coding"
    assert loaded.episodic_validation.validation_threshold == 0.5
  end

  @tag :tmp_dir
  test "load/1 rejects unknown extraction_profile and falls back to none", %{tmp_dir: tmp_dir} do
    config_path = Settings.ensure_defaults!(home: tmp_dir)

    File.write!(
      config_path,
      """
      [paths]
      memory = "memory"

      [llm]
      provider = "openai"
      model = "gpt-4o-mini"

      [embeddings]
      provider = "openai"
      model = "text-embedding-3-small"

      [server]
      host = "127.0.0.1"
      port = 4000

      [mnemosyne]
      extraction_profile = "totally-invalid"
      """
    )

    llm_resolver = fn
      "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    embedding_resolver = fn
      "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
      _ -> {:error, :unknown_model}
    end

    settings =
      Settings.load(
        home: tmp_dir,
        llm_resolver: llm_resolver,
        embedding_resolver: embedding_resolver
      )

    assert settings.mnemosyne.extraction_profile == "none"
  end

  describe "overrides and value_function" do
    @tag :tmp_dir
    test "load/1 parses per-step overrides and value_function params", %{tmp_dir: tmp_dir} do
      config_path = Settings.ensure_defaults!(home: tmp_dir)

      File.write!(
        config_path,
        """
        [paths]
        memory = "memory"

        [llm]
        provider = "openai"
        model = "gpt-4o-mini"

        [embeddings]
        provider = "openai"
        model = "text-embedding-3-small"

        [server]
        host = "127.0.0.1"
        port = 4000

        [overrides.structuring]
        model = "gpt-4o-mini"

        [overrides.structuring.opts]
        temperature = 0.0

        [overrides.retrieval.opts]
        max_tokens = 512

        [value_function.params.semantic]
        threshold = 0.42
        """
      )

      llm_resolver = fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      embedding_resolver = fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      settings =
        Settings.load(
          home: tmp_dir,
          llm_resolver: llm_resolver,
          embedding_resolver: embedding_resolver
        )

      assert settings.overrides["structuring"] == %{
               model: "gpt-4o-mini",
               temperature: 0.0,
               max_tokens: nil
             }

      assert settings.overrides["retrieval"] == %{
               model: nil,
               temperature: nil,
               max_tokens: 512
             }

      semantic = settings.value_function["semantic"]
      assert semantic["threshold"] == 0.42
      assert semantic["top_k"] == 20
      assert semantic["lambda"] == 0.01
      assert semantic["k"] == 5
    end

    @tag :tmp_dir
    test "load/1 drops unknown pipeline steps and node types", %{tmp_dir: tmp_dir} do
      config_path = Settings.ensure_defaults!(home: tmp_dir)

      File.write!(
        config_path,
        """
        [paths]
        memory = "memory"

        [llm]
        provider = "openai"
        model = "gpt-4o-mini"

        [embeddings]
        provider = "openai"
        model = "text-embedding-3-small"

        [server]
        host = "127.0.0.1"
        port = 4000

        [overrides.not_a_real_step]
        model = "ignored"

        [value_function.params.bogus_type]
        threshold = 0.99
        """
      )

      llm_resolver = fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      embedding_resolver = fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      settings =
        Settings.load(
          home: tmp_dir,
          llm_resolver: llm_resolver,
          embedding_resolver: embedding_resolver
        )

      refute Map.has_key?(settings.overrides, "not_a_real_step")
      refute Map.has_key?(settings.value_function, "bogus_type")
      assert Map.has_key?(settings.value_function, "semantic")
    end

    @tag :tmp_dir
    test "save/2 round-trips overrides and value_function params", %{tmp_dir: tmp_dir} do
      attrs = %{
        "paths" => %{"memory" => "memory"},
        "llm" => %{"provider" => "openai", "model" => "gpt-4o-mini"},
        "embeddings" => %{"provider" => "openai", "model" => "text-embedding-3-small"},
        "server" => %{"host" => "127.0.0.1", "port" => 4000},
        "overrides" => %{
          "structuring" => %{"model" => "gpt-4o-mini", "temperature" => 0.0}
        },
        "value_function" => %{
          "semantic" => %{"threshold" => 0.42, "top_k" => 25}
        }
      }

      llm_resolver = fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      embedding_resolver = fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      assert {:ok, _saved} =
               Settings.save(attrs,
                 home: tmp_dir,
                 llm_resolver: llm_resolver,
                 embedding_resolver: embedding_resolver
               )

      loaded =
        Settings.load(
          home: tmp_dir,
          llm_resolver: llm_resolver,
          embedding_resolver: embedding_resolver
        )

      assert loaded.overrides["structuring"].model == "gpt-4o-mini"
      assert loaded.overrides["structuring"].temperature == 0.0
      assert loaded.value_function["semantic"]["threshold"] == 0.42
      assert loaded.value_function["semantic"]["top_k"] == 25
      assert loaded.value_function["semantic"]["lambda"] == 0.01
    end

    @tag :tmp_dir
    test "mnemosyne_runtime/1 converts string keys to atoms and drops empty overrides",
         %{tmp_dir: tmp_dir} do
      settings = %Settings{
        home: tmp_dir,
        paths: %{memory: "memory"},
        llm: %{provider: "openai", model: "gpt-4o-mini"},
        embeddings: %{provider: "openai", model: "text-embedding-3-small"},
        server: %{host: "127.0.0.1", port: 4000},
        mnemosyne: @default_mnemosyne,
        episodic_validation: @default_episodic_validation,
        summaries: @default_summaries,
        overrides: %{
          "structuring" => %{model: "gpt-4o-mini", temperature: 0.0, max_tokens: nil},
          "retrieval" => %{model: nil, temperature: nil, max_tokens: 512},
          "extract" => %{model: nil, temperature: nil, max_tokens: nil}
        },
        value_function: %{
          "semantic" => %{
            "threshold" => 0.42,
            "top_k" => 20,
            "lambda" => 0.01,
            "k" => 5,
            "base_floor" => 0.3,
            "beta" => 1.0
          }
        },
        issues: [],
        ready?: true
      }

      runtime = Settings.mnemosyne_runtime(settings)

      assert runtime.mnemosyne_config.overrides[:structuring] ==
               %{model: "gpt-4o-mini", opts: %{temperature: 0.0}}

      assert runtime.mnemosyne_config.overrides[:retrieval] == %{opts: %{max_tokens: 512}}
      refute Map.has_key?(runtime.mnemosyne_config.overrides, :extract)

      assert runtime.mnemosyne_config.value_function.module == Mnemosyne.ValueFunction.Default

      assert runtime.mnemosyne_config.value_function.params[:semantic] ==
               %{threshold: 0.42, top_k: 20, lambda: 0.01, k: 5, base_floor: 0.3, beta: 1.0}
    end

    @tag :tmp_dir
    test "load/1 fills in Mnemosyne-matching defaults when sections are absent",
         %{tmp_dir: tmp_dir} do
      _config_path = Settings.ensure_defaults!(home: tmp_dir)

      llm_resolver = fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      embedding_resolver = fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end

      settings =
        Settings.load(
          home: tmp_dir,
          llm_resolver: llm_resolver,
          embedding_resolver: embedding_resolver
        )

      for step <- Settings.pipeline_steps() do
        assert Map.has_key?(settings.overrides, step)
        assert settings.overrides[step] == %{model: nil, temperature: nil, max_tokens: nil}
      end

      assert settings.value_function["semantic"]["top_k"] == 20
      assert settings.value_function["procedural"]["threshold"] == 0.8
      assert settings.value_function["source"]["top_k"] == 50
    end
  end
end
