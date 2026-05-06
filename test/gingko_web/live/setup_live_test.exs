defmodule GingkoWeb.SetupLiveTest do
  use GingkoWeb.ConnCase, async: false
  use Mimic

  alias Gingko.Credentials
  alias Gingko.Credentials.Runtime
  alias Gingko.Providers.GithubCopilotAuth
  alias Gingko.Settings

  setup do
    previous = Application.get_env(:gingko, :settings_opts, [])
    previous_settings = Application.get_env(:gingko, :settings)
    previous_memory = Application.get_env(:gingko, Gingko.Memory)

    on_exit(fn ->
      Application.put_env(:gingko, :settings_opts, previous)

      if previous_settings == nil do
        Application.delete_env(:gingko, :settings)
      else
        Application.put_env(:gingko, :settings, previous_settings)
      end

      if previous_memory == nil do
        Application.delete_env(:gingko, Gingko.Memory)
      else
        Application.put_env(:gingko, Gingko.Memory, previous_memory)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "renders current settings and model fields", %{conn: conn, tmp_dir: tmp_dir} do
    Application.put_env(
      :gingko,
      :settings_opts,
      home: tmp_dir,
      llm_resolver: fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end,
      embedding_resolver: fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end
    )

    {:ok, _view, html} = live conn, ~p"/setup"

    assert html =~ "Workspace"
    assert html =~ "Setup"
    assert html =~ "Projects"
    assert html =~ "System Theme"
    assert html =~ "Setup Required"
    assert html =~ "text-embedding-3-small"
    assert html =~ "Memory Engine"
  end

  @tag :tmp_dir
  test "saving mixed-provider settings persists them and updates the UI", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    Application.put_env(
      :gingko,
      :settings_opts,
      home: tmp_dir,
      llm_resolver: fn
        "anthropic:claude-sonnet-4" -> {:ok, %{provider: :anthropic}}
        _ -> {:error, :unknown_model}
      end,
      embedding_resolver: fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end
    )

    {:ok, view, _html} = live conn, ~p"/setup"

    params = %{
      "settings" => %{
        "paths" => %{"memory" => "custom-memory"},
        "llm" => %{"provider" => "anthropic", "model" => "claude-sonnet-4"},
        "embeddings" => %{"provider" => "openai", "model" => "text-embedding-3-small"},
        "server" => %{"host" => "0.0.0.0", "port" => "4010"},
        "mnemosyne" => %{
          "intent_merge_threshold" => "0.8",
          "intent_identity_threshold" => "0.95",
          "refinement_threshold" => "0.6",
          "auto_commit" => "true",
          "flush_timeout_ms" => "120000",
          "session_timeout_ms" => "600000",
          "trace_verbosity" => "summary"
        }
      }
    }

    view
    |> form("#settings-form", params)
    |> render_submit()

    assert_redirect view, ~p"/projects"

    settings = Settings.load(home: tmp_dir)

    assert settings.paths.memory == "custom-memory"
    assert settings.llm.provider == "anthropic"
    assert settings.server.port == 4010
  end

  @tag :tmp_dir
  test "changing embeddings provider to bumblebee updates the form immediately", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    Application.put_env(
      :gingko,
      :settings_opts,
      home: tmp_dir,
      llm_resolver: fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end,
      embedding_resolver: fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end
    )

    {:ok, view, _html} = live conn, ~p"/setup"

    html =
      view
      |> form("#settings-form", %{
        "settings" => %{
          "paths" => %{"memory" => "memory"},
          "llm" => %{"provider" => "openai", "model" => "gpt-4o-mini"},
          "embeddings" => %{"provider" => "bumblebee", "model" => "intfloat/e5-base-v2"},
          "server" => %{"host" => "127.0.0.1", "port" => "4000"},
          "mnemosyne" => %{
            "intent_merge_threshold" => "0.8",
            "intent_identity_threshold" => "0.95",
            "refinement_threshold" => "0.6",
            "auto_commit" => "true",
            "flush_timeout_ms" => "120000",
            "session_timeout_ms" => "600000",
            "trace_verbosity" => "summary"
          }
        }
      })
      |> render_change()

    assert html =~ "embedding model automatically"
  end

  @tag :tmp_dir
  test "mnemosyne config section renders with default values", %{conn: conn, tmp_dir: tmp_dir} do
    Application.put_env(
      :gingko,
      :settings_opts,
      home: tmp_dir,
      llm_resolver: fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end,
      embedding_resolver: fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end
    )

    {:ok, _view, html} = live conn, ~p"/setup"

    assert html =~ "Memory Engine"
    assert html =~ "Intent merge threshold"
    assert html =~ "Refinement threshold"
    assert html =~ "Refinement budget"
    assert html =~ "Plateau delta"
    assert html =~ "Extraction profile"
    assert html =~ "Consolidation threshold"
    assert html =~ "Decay threshold"
    assert html =~ "Flush timeout"
    assert html =~ "Session timeout"
    assert html =~ "Trace verbosity"
  end

  @tag :tmp_dir
  test "setup screen renders tabs and switches active panel on click", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    Application.put_env(
      :gingko,
      :settings_opts,
      home: tmp_dir,
      llm_resolver: fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end,
      embedding_resolver: fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end
    )

    {:ok, view, html} = live conn, ~p"/setup"

    for tab_label <- [
          "General",
          "Models",
          "Memory Engine",
          "Retrieval Validation",
          "Summaries"
        ] do
      assert html =~ tab_label
    end

    assert html =~ "Episodic Validation"

    next_html =
      view
      |> element("button[phx-value-tab=\"validation\"]")
      |> render_click()

    assert next_html =~ "tab-active"
    assert next_html =~ "Episodic Validation"
  end

  @tag :tmp_dir
  test "renders Retrieval Validation inputs with defaults", %{conn: conn, tmp_dir: tmp_dir} do
    Application.put_env(
      :gingko,
      :settings_opts,
      home: tmp_dir,
      llm_resolver: fn
        "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end,
      embedding_resolver: fn
        "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
        _ -> {:error, :unknown_model}
      end
    )

    {:ok, _view, html} = live conn, ~p"/setup"

    assert html =~ "Validation threshold"
    assert html =~ "Orphan penalty"
    assert html =~ "Weak grounding penalty"
  end

  describe "[summaries] section" do
    @tag :tmp_dir
    test "renders the Memory Summaries section with all fields and defaults", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      Application.put_env(
        :gingko,
        :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end
      )

      {:ok, _view, html} = live conn, ~p"/setup"

      assert html =~ "Memory Summaries"
      assert html =~ "Enabled"
      assert html =~ "Regen debounce seconds"
      assert html =~ "Summary memory count"
      assert html =~ "Session primer recent count"
      assert html =~ "Step summarization"
      assert html =~ "Chunk size (chars)"
      assert html =~ "Max chunks"
      assert html =~ "Parallelism"
      assert html =~ "Per-chunk timeout (ms)"
    end

    @tag :tmp_dir
    test "saving the summaries fields round-trips through config.toml and Settings.load/1",
         %{conn: conn, tmp_dir: tmp_dir} do
      Application.put_env(
        :gingko,
        :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end
      )

      {:ok, view, _html} = live conn, ~p"/setup"

      params = %{
        "settings" => %{
          "paths" => %{"memory" => "memory"},
          "llm" => %{"provider" => "openai", "model" => "gpt-4o-mini"},
          "embeddings" => %{
            "provider" => "openai",
            "model" => "text-embedding-3-small"
          },
          "server" => %{"host" => "127.0.0.1", "port" => "4000"},
          "mnemosyne" => %{
            "intent_merge_threshold" => "0.8",
            "intent_identity_threshold" => "0.95",
            "refinement_threshold" => "0.6",
            "auto_commit" => "true",
            "flush_timeout_ms" => "120000",
            "session_timeout_ms" => "600000",
            "trace_verbosity" => "summary"
          },
          "summaries" => %{
            "enabled" => "true",
            "regen_debounce_seconds" => "45",
            "summary_memory_count" => "150",
            "session_primer_recent_count" => "11",
            "chunk_chars" => "200000",
            "max_chunks" => "4",
            "parallelism" => "2",
            "chunk_timeout_ms" => "45000"
          }
        }
      }

      view
      |> form("#settings-form", params)
      |> render_submit()

      assert_redirect view, ~p"/projects"

      settings = Settings.load(home: tmp_dir)

      assert settings.summaries.enabled == true
      assert settings.summaries.regen_debounce_seconds == 45
      assert settings.summaries.summary_memory_count == 150
      assert settings.summaries.session_primer_recent_count == 11
      assert settings.summaries.chunk_chars == 200_000
      assert settings.summaries.max_chunks == 4
      assert settings.summaries.parallelism == 2
      assert settings.summaries.chunk_timeout_ms == 45_000
    end
  end

  describe "pipeline overrides and value_function tabs" do
    @tag :tmp_dir
    test "renders both new tab labels and their default content", %{conn: conn, tmp_dir: tmp_dir} do
      Application.put_env(
        :gingko,
        :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end
      )

      {:ok, _view, html} = live conn, ~p"/setup"

      assert html =~ "Pipeline Overrides"
      assert html =~ "Value Function"
      assert html =~ "Per-step LLM overrides"
      assert html =~ "Value function parameters"

      for step <- ["structuring", "retrieval", "summarize"], do: assert(html =~ step)
      for type <- ["semantic", "procedural", "episodic", "subgoal"], do: assert(html =~ type)
    end

    @tag :tmp_dir
    test "saving the overrides tab round-trips a per-step model through config.toml", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      Application.put_env(
        :gingko,
        :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end
      )

      {:ok, view, _html} = live conn, ~p"/setup"

      empty_override = %{"model" => "", "temperature" => "", "max_tokens" => ""}

      overrides_payload =
        Map.new(Settings.pipeline_steps(), fn step -> {step, empty_override} end)
        |> Map.put("structuring", %{
          "model" => "gpt-4o-mini",
          "temperature" => "0.1",
          "max_tokens" => ""
        })

      vf_payload =
        Map.new(Settings.node_types(), fn type ->
          defaults = Settings.value_function_defaults()[type]

          {type,
           Map.new(Settings.value_function_param_keys(), fn key ->
             {key, to_string(Map.fetch!(defaults, key))}
           end)}
        end)

      params = %{
        "settings" => %{
          "paths" => %{"memory" => "memory"},
          "llm" => %{"provider" => "openai", "model" => "gpt-4o-mini"},
          "embeddings" => %{"provider" => "openai", "model" => "text-embedding-3-small"},
          "server" => %{"host" => "127.0.0.1", "port" => "4000"},
          "mnemosyne" => %{
            "intent_merge_threshold" => "0.8",
            "intent_identity_threshold" => "0.95",
            "refinement_threshold" => "0.6",
            "auto_commit" => "true",
            "flush_timeout_ms" => "120000",
            "session_timeout_ms" => "600000",
            "trace_verbosity" => "summary"
          },
          "overrides" => overrides_payload,
          "value_function" => vf_payload
        }
      }

      view
      |> form("#settings-form", params)
      |> render_submit()

      assert_redirect view, ~p"/projects"

      settings = Settings.load(home: tmp_dir)

      assert settings.overrides["structuring"].model == "gpt-4o-mini"
      assert settings.overrides["structuring"].temperature == 0.1
      assert settings.overrides["retrieval"] == %{model: nil, temperature: nil, max_tokens: nil}
      assert settings.value_function["semantic"]["top_k"] == 20
    end

    @tag :tmp_dir
    test "saving edited value_function params persists them", %{conn: conn, tmp_dir: tmp_dir} do
      Application.put_env(
        :gingko,
        :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end
      )

      {:ok, view, _html} = live conn, ~p"/setup"

      empty_override = %{"model" => "", "temperature" => "", "max_tokens" => ""}

      overrides_payload =
        Map.new(Settings.pipeline_steps(), fn step -> {step, empty_override} end)

      vf_payload =
        Map.new(Settings.node_types(), fn type ->
          defaults = Settings.value_function_defaults()[type]

          params =
            Map.new(Settings.value_function_param_keys(), fn key ->
              {key, to_string(Map.fetch!(defaults, key))}
            end)

          {type, params}
        end)
        |> put_in(["semantic", "threshold"], "0.55")
        |> put_in(["semantic", "top_k"], "42")

      params = %{
        "settings" => %{
          "paths" => %{"memory" => "memory"},
          "llm" => %{"provider" => "openai", "model" => "gpt-4o-mini"},
          "embeddings" => %{"provider" => "openai", "model" => "text-embedding-3-small"},
          "server" => %{"host" => "127.0.0.1", "port" => "4000"},
          "mnemosyne" => %{
            "intent_merge_threshold" => "0.8",
            "intent_identity_threshold" => "0.95",
            "refinement_threshold" => "0.6",
            "auto_commit" => "true",
            "flush_timeout_ms" => "120000",
            "session_timeout_ms" => "600000",
            "trace_verbosity" => "summary"
          },
          "overrides" => overrides_payload,
          "value_function" => vf_payload
        }
      }

      view
      |> form("#settings-form", params)
      |> render_submit()

      settings = Settings.load(home: tmp_dir)

      assert settings.value_function["semantic"]["threshold"] == 0.55
      assert settings.value_function["semantic"]["top_k"] == 42
      assert settings.value_function["procedural"]["threshold"] == 0.8
    end
  end

  describe "[models] provider/model combobox" do
    @tag :tmp_dir
    test "renders provider and model options for the loaded provider", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      Application.put_env(
        :gingko,
        :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        providers_source: fn -> [:openai, :anthropic] end,
        models_source: fn
          :openai ->
            [
              %{id: "gpt-4o", modalities: %{output: [:text]}},
              %{id: "gpt-4o-mini", modalities: %{output: [:text]}},
              %{id: "text-embedding-3-small", modalities: %{output: [:embedding]}}
            ]

          :anthropic ->
            [%{id: "claude-sonnet-4", modalities: %{output: [:text]}}]

          _ ->
            []
        end
      )

      {:ok, _view, html} = live conn, ~p"/setup"

      assert html =~ ~s(data-value="openai")
      assert html =~ ~s(data-value="anthropic")
      assert html =~ ~s(data-value="gpt-4o")
      assert html =~ ~s(data-value="gpt-4o-mini")
      assert html =~ ~s(data-value="text-embedding-3-small")
    end

    @tag :tmp_dir
    test "changing the provider clears the model field and refreshes the model list", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      Application.put_env(
        :gingko,
        :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "openai:gpt-4o-mini" -> {:ok, %{provider: :openai}}
          "anthropic:claude-sonnet-4" -> {:ok, %{provider: :anthropic}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        providers_source: fn -> [:openai, :anthropic] end,
        models_source: fn
          :openai ->
            [
              %{id: "gpt-4o-mini", modalities: %{output: [:text]}},
              %{id: "text-embedding-3-small", modalities: %{output: [:embedding]}}
            ]

          :anthropic ->
            [%{id: "claude-sonnet-4", modalities: %{output: [:text]}}]

          _ ->
            []
        end
      )

      {:ok, view, html} = live conn, ~p"/setup"
      assert html =~ ~s(data-value="gpt-4o-mini")
      refute html =~ ~s(data-value="claude-sonnet-4")

      new_html =
        view
        |> form("#settings-form", %{
          "settings" => %{
            "paths" => %{"memory" => "memory"},
            "llm" => %{"provider" => "anthropic", "model" => "gpt-4o-mini"},
            "embeddings" => %{
              "provider" => "openai",
              "model" => "text-embedding-3-small"
            },
            "server" => %{"host" => "127.0.0.1", "port" => "4000"},
            "mnemosyne" => %{
              "intent_merge_threshold" => "0.8",
              "intent_identity_threshold" => "0.95",
              "refinement_threshold" => "0.6",
              "auto_commit" => "true",
              "flush_timeout_ms" => "120000",
              "session_timeout_ms" => "600000",
              "trace_verbosity" => "summary"
            }
          }
        })
        |> render_change()

      assert new_html =~ ~s(data-value="claude-sonnet-4")
      refute new_html =~ ~s(data-value="gpt-4o-mini")

      [_, model_input] = Regex.run(~r/(<input[^>]*id="settings_llm_0_model"[^>]*>)/, new_html)
      refute model_input =~ ~s(value="gpt-4o-mini")
      refute model_input =~ ~s(value="claude-sonnet-4")
    end
  end

  describe "[copilot] device-flow auth" do
    setup :set_mimic_global

    setup do
      Mimic.copy(Runtime)
      Mimic.copy(GithubCopilotAuth)
      stub(Runtime, :put_provider, fn _, _ -> :ok end)
      stub(Runtime, :delete_provider, fn _ -> :ok end)
      :ok
    end

    defp seed_copilot_provider(tmp_dir) do
      Application.put_env(:gingko, :settings_opts,
        home: tmp_dir,
        llm_resolver: fn
          "github_copilot:gpt-4o" -> {:ok, %{provider: :github_copilot}}
          _ -> {:error, :unknown_model}
        end,
        embedding_resolver: fn
          "openai:text-embedding-3-small" -> {:ok, %{provider: :openai}}
          _ -> {:error, :unknown_model}
        end,
        providers_source: fn -> [:github_copilot, :openai] end,
        models_source: fn
          :github_copilot -> [%{id: "gpt-4o", modalities: %{output: [:text]}}]
          :openai -> [%{id: "text-embedding-3-small", modalities: %{output: [:embedding]}}]
          _ -> []
        end
      )

      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "config.toml"), """
      [paths]
      memory = "memory"

      [llm]
      provider = "github_copilot"
      model = "gpt-4o"

      [embeddings]
      provider = "openai"
      model = "text-embedding-3-small"

      [server]
      host = "127.0.0.1"
      port = 4000
      """)
    end

    @tag :tmp_dir
    test "shows the auth panel when github_copilot is selected", %{conn: conn, tmp_dir: tmp_dir} do
      seed_copilot_provider(tmp_dir)

      {:ok, _view, html} = live conn, ~p"/setup"

      assert html =~ "GitHub Copilot authentication"
      assert html =~ "Authenticate with GitHub"
    end

    @tag :tmp_dir
    test "starts the device flow and renders the user code", %{conn: conn, tmp_dir: tmp_dir} do
      seed_copilot_provider(tmp_dir)

      expect(GithubCopilotAuth, :start_device_flow, fn ->
        {:ok,
         %{
           device_code: "dc",
           user_code: "WXYZ-1234",
           verification_uri: "https://github.com/login/device",
           interval: 5,
           expires_in: 900
         }}
      end)

      stub(GithubCopilotAuth, :poll_for_token, fn "dc", 5 ->
        Process.sleep(:infinity)
      end)

      {:ok, view, _html} = live conn, ~p"/setup"

      html = view |> element("button", "Authenticate with GitHub") |> render_click()

      assert html =~ "WXYZ-1234"
      assert html =~ "https://github.com/login/device"
      assert html =~ "Awaiting approval"
    end

    @tag :tmp_dir
    test "stores token on successful poll and shows masked token", %{conn: conn, tmp_dir: tmp_dir} do
      seed_copilot_provider(tmp_dir)

      expect(GithubCopilotAuth, :start_device_flow, fn ->
        {:ok,
         %{
           device_code: "dc",
           user_code: "WXYZ-1234",
           verification_uri: "https://github.com/login/device",
           interval: 5,
           expires_in: 900
         }}
      end)

      expect(GithubCopilotAuth, :poll_for_token, fn "dc", 5 -> {:ok, "gho_supersecret"} end)
      expect(GithubCopilotAuth, :verify_token, fn "gho_supersecret" -> {:ok, %{}} end)

      {:ok, view, _html} = live conn, ~p"/setup"
      view |> element("button", "Authenticate with GitHub") |> render_click()

      html = render_async(view)

      assert html =~ "Authenticated"
      assert html =~ "gho_…cret"
      assert Credentials.get(:github_copilot, :github_token) == "gho_supersecret"
    end

    @tag :tmp_dir
    test "logout clears stored credentials", %{conn: conn, tmp_dir: tmp_dir} do
      seed_copilot_provider(tmp_dir)

      {:ok, _} = Credentials.put(:github_copilot, :github_token, "gho_alreadythere")

      {:ok, view, html} = live conn, ~p"/setup"
      assert html =~ "Authenticated"

      html = view |> element("button", "Sign out") |> render_click()

      assert html =~ "Authenticate with GitHub"
      assert Credentials.get(:github_copilot, :github_token) == nil
    end
  end
end
