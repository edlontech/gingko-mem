defmodule Gingko.Settings do
  @moduledoc """
  Runtime settings boundary for user-managed Gingko configuration.

  This module owns application-home resolution, default TOML bootstrapping,
  settings loading/saving, and translation into Gingko memory runtime options.
  """

  @default_paths %{"memory" => "memory"}
  @default_bumblebee_embedding_model "intfloat/e5-base-v2"
  @default_llm %{"provider" => "openai", "model" => "gpt-4o-mini"}
  @default_embeddings %{"provider" => "openai", "model" => "text-embedding-3-small"}
  @default_server %{"host" => "127.0.0.1", "port" => 8008}
  @default_mnemosyne %{
    "intent_merge_threshold" => 0.8,
    "intent_identity_threshold" => 0.95,
    "refinement_threshold" => 0.6,
    "refinement_budget" => 1,
    "plateau_delta" => 0.05,
    "extraction_profile" => "none",
    "consolidation_threshold" => 0.85,
    "decay_threshold" => 0.1,
    "auto_commit" => true,
    "flush_timeout_ms" => 120_000,
    "session_timeout_ms" => 600_000,
    "trace_verbosity" => "summary"
  }
  @default_episodic_validation %{
    "validation_threshold" => 0.3,
    "orphan_penalty" => 0.3,
    "weak_grounding_penalty" => 0.1
  }
  @default_summaries %{
    "enabled" => false,
    "hot_tags_k" => 15,
    "cluster_regen_memory_threshold" => 10,
    "cluster_regen_idle_seconds" => 1800,
    "principal_regen_debounce_seconds" => 60,
    "session_primer_recent_count" => 15
  }
  @pipeline_steps ~w(
    structuring extract retrieval summarize merge_intent
    get_refined_query get_semantic get_procedural get_state
    get_subgoal get_plan get_mode get_reward get_return
    reason_semantic reason_procedural reason_episodic
  )
  @node_types ~w(semantic procedural episodic subgoal tag source intent)
  @vf_param_keys ~w(threshold top_k lambda k base_floor beta)
  @vf_integer_keys ~w(top_k k)
  @vf_param_defaults %{
    "semantic" => %{
      "threshold" => 0.0,
      "top_k" => 20,
      "lambda" => 0.01,
      "k" => 5,
      "base_floor" => 0.3,
      "beta" => 1.0
    },
    "procedural" => %{
      "threshold" => 0.8,
      "top_k" => 10,
      "lambda" => 0.01,
      "k" => 5,
      "base_floor" => 0.3,
      "beta" => 1.0
    },
    "episodic" => %{
      "threshold" => 0.0,
      "top_k" => 30,
      "lambda" => 0.01,
      "k" => 5,
      "base_floor" => 0.3,
      "beta" => 1.0
    },
    "subgoal" => %{
      "threshold" => 0.75,
      "top_k" => 10,
      "lambda" => 0.01,
      "k" => 5,
      "base_floor" => 0.3,
      "beta" => 1.0
    },
    "tag" => %{
      "threshold" => 0.9,
      "top_k" => 10,
      "lambda" => 0.01,
      "k" => 5,
      "base_floor" => 0.3,
      "beta" => 1.0
    },
    "source" => %{
      "threshold" => 0.0,
      "top_k" => 50,
      "lambda" => 0.01,
      "k" => 5,
      "base_floor" => 0.3,
      "beta" => 1.0
    },
    "intent" => %{
      "threshold" => 0.7,
      "top_k" => 10,
      "lambda" => 0.01,
      "k" => 5,
      "base_floor" => 0.3,
      "beta" => 1.0
    }
  }
  @default_overrides %{}

  @enforce_keys [
    :home,
    :paths,
    :llm,
    :embeddings,
    :server,
    :mnemosyne,
    :episodic_validation,
    :summaries,
    :overrides,
    :value_function,
    :issues,
    :ready?
  ]
  defstruct [
    :home,
    :paths,
    :llm,
    :embeddings,
    :server,
    :mnemosyne,
    :episodic_validation,
    :summaries,
    :overrides,
    :value_function,
    :issues,
    :ready?
  ]

  @type t :: %__MODULE__{
          home: String.t(),
          paths: %{memory: String.t()},
          llm: %{provider: String.t(), model: String.t()},
          embeddings: %{provider: String.t(), model: String.t()},
          server: %{host: String.t(), port: pos_integer()},
          mnemosyne: %{
            intent_merge_threshold: float(),
            intent_identity_threshold: float(),
            refinement_threshold: float(),
            refinement_budget: non_neg_integer(),
            plateau_delta: float(),
            extraction_profile: String.t(),
            consolidation_threshold: float(),
            decay_threshold: float(),
            auto_commit: boolean(),
            flush_timeout_ms: pos_integer(),
            session_timeout_ms: pos_integer(),
            trace_verbosity: String.t()
          },
          episodic_validation: %{
            validation_threshold: float(),
            orphan_penalty: float(),
            weak_grounding_penalty: float()
          },
          summaries: %{
            enabled: boolean(),
            hot_tags_k: pos_integer(),
            cluster_regen_memory_threshold: pos_integer(),
            cluster_regen_idle_seconds: pos_integer(),
            principal_regen_debounce_seconds: pos_integer(),
            session_primer_recent_count: pos_integer()
          },
          overrides: %{
            optional(String.t()) => %{
              model: String.t() | nil,
              temperature: float() | nil,
              max_tokens: pos_integer() | nil
            }
          },
          value_function: %{
            optional(String.t()) => %{
              threshold: float(),
              top_k: pos_integer(),
              lambda: float(),
              k: pos_integer(),
              base_floor: float(),
              beta: float()
            }
          },
          issues: [map()],
          ready?: boolean()
        }

  @spec pipeline_steps() :: [String.t()]
  def pipeline_steps, do: @pipeline_steps

  @spec node_types() :: [String.t()]
  def node_types, do: @node_types

  @spec value_function_param_keys() :: [String.t()]
  def value_function_param_keys, do: @vf_param_keys

  @spec value_function_defaults() :: %{
          optional(String.t()) => %{optional(String.t()) => number()}
        }
  def value_function_defaults, do: @vf_param_defaults

  @spec home(keyword()) :: String.t()
  def home(opts \\ []) do
    case Keyword.get(opts, :home) do
      value when is_binary(value) and value != "" ->
        Path.expand(value)

      _ ->
        env = Keyword.get(opts, :env, &System.get_env/1)
        env.("GINGKO_HOME") || Path.expand("~/.gingko")
    end
  end

  @spec ensure_defaults!(keyword()) :: String.t()
  def ensure_defaults!(opts \\ []) do
    app_home = home(opts)
    config_path = Path.join(app_home, "config.toml")
    memory_path = Path.join(app_home, @default_paths["memory"])

    File.mkdir_p!(app_home)
    File.mkdir_p!(memory_path)

    if not File.exists?(config_path) do
      File.write!(config_path, default_toml!())
    end

    config_path
  end

  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    config_path = ensure_defaults!(opts)
    app_home = home(opts)

    {decoded, parse_issues} =
      case File.read(config_path) do
        {:ok, content} ->
          case TomlElixir.decode(content) do
            {:ok, map} when is_map(map) -> {map, []}
            {:error, error} -> {%{}, [issue("config", error_message(error))]}
          end

        {:error, error} ->
          {%{}, [issue("config", error_message(error))]}
      end

    parsed = parsed_config(decoded)
    validation_issues = validate(parsed, opts)
    issues = parse_issues ++ validation_issues

    %__MODULE__{
      home: app_home,
      paths: parsed.paths,
      llm: parsed.llm,
      embeddings: parsed.embeddings,
      server: parsed.server,
      mnemosyne: parsed.mnemosyne,
      episodic_validation: parsed.episodic_validation,
      summaries: parsed.summaries,
      overrides: parsed.overrides,
      value_function: parsed.value_function,
      issues: issues,
      ready?: issues == []
    }
  end

  @spec preview(map(), keyword()) :: t()
  def preview(attrs, opts \\ []) when is_map(attrs) do
    app_home = home(opts)
    parsed = parsed_config(attrs)
    issues = validate(parsed, opts)

    %__MODULE__{
      home: app_home,
      paths: parsed.paths,
      llm: parsed.llm,
      embeddings: parsed.embeddings,
      server: parsed.server,
      mnemosyne: parsed.mnemosyne,
      episodic_validation: parsed.episodic_validation,
      summaries: parsed.summaries,
      overrides: parsed.overrides,
      value_function: parsed.value_function,
      issues: issues,
      ready?: issues == []
    }
  end

  @spec save(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def save(attrs, opts \\ []) when is_map(attrs) do
    app_home = home(opts)
    config_path = ensure_defaults!(opts)

    parsed = parsed_config(attrs)

    with {:ok, toml} <- TomlElixir.encode(to_toml_map(parsed)),
         :ok <- File.write(config_path, toml) do
      {:ok, load(Keyword.put(opts, :home, app_home))}
    else
      {:error, error} -> {:error, error}
    end
  end

  @spec memory_root(t()) :: String.t()
  def memory_root(%__MODULE__{home: home, paths: %{memory: relative_path}}) do
    Path.expand(relative_path, home)
  end

  @spec metadata_db_path(t()) :: String.t()
  def metadata_db_path(%__MODULE__{home: home}) do
    Path.join(home, "metadata.sqlite3")
  end

  @spec summaries_env(t()) :: keyword()
  def summaries_env(%__MODULE__{summaries: summaries}) do
    [
      enabled: summaries.enabled,
      hot_tags_k: summaries.hot_tags_k,
      cluster_regen_memory_threshold: summaries.cluster_regen_memory_threshold,
      cluster_regen_idle_seconds: summaries.cluster_regen_idle_seconds,
      principal_regen_debounce_seconds: summaries.principal_regen_debounce_seconds,
      session_primer_recent_count: summaries.session_primer_recent_count
    ]
  end

  @spec mnemosyne_runtime(t()) :: map()
  def mnemosyne_runtime(%__MODULE__{} = settings) do
    embedding_runtime = embedding_runtime(settings.embeddings)
    config = build_mnemosyne_config_map(settings, embedding_runtime)

    %{
      storage_root: memory_root(settings),
      mnemosyne_config: config,
      llm_adapter: Mnemosyne.Adapters.SycophantLLM,
      embedding_adapter: embedding_runtime.adapter
    }
  end

  @doc """
  Builds a project-scoped `%Mnemosyne.Config{}` by applying an
  `ExtractionOverlay` on top of the global profile.

  When the overlay is `empty?/1`, the returned config is equivalent to
  the global `mnemosyne_runtime/1` config converted to a struct.
  """
  @spec project_mnemosyne_config(t(), Gingko.Projects.ExtractionOverlay.t()) ::
          Mnemosyne.Config.t()
  def project_mnemosyne_config(%__MODULE__{} = settings, overlay) do
    embedding_runtime = embedding_runtime(settings.embeddings)
    base_map = build_mnemosyne_config_map(settings, embedding_runtime, skip_profile: true)
    global = global_extraction_profile(settings.mnemosyne.extraction_profile)
    effective = Gingko.Projects.ExtractionOverlay.to_extraction_profile(overlay, global)

    base_map
    |> maybe_put_profile_struct(effective)
    |> then(&struct!(Mnemosyne.Config, &1))
  end

  @doc """
  Returns the global `%Mnemosyne.ExtractionProfile{}` for the given profile
  name, or nil when the name is unknown or `"none"`.
  """
  @spec global_extraction_profile(String.t() | nil) :: Mnemosyne.ExtractionProfile.t() | nil
  def global_extraction_profile("coding"), do: Mnemosyne.ExtractionProfile.coding()
  def global_extraction_profile("research"), do: Mnemosyne.ExtractionProfile.research()

  def global_extraction_profile("customer_support"),
    do: Mnemosyne.ExtractionProfile.customer_support()

  def global_extraction_profile(_), do: nil

  defp build_mnemosyne_config_map(settings, embedding_runtime, opts \\ []) do
    mn = settings.mnemosyne
    ev = settings.episodic_validation

    base = %{
      llm: %{model: qualified_model(settings.llm), opts: %{}},
      embedding: embedding_runtime.config,
      overrides: atomize_overrides(settings.overrides),
      value_function: %{
        module: Mnemosyne.ValueFunction.Default,
        params: atomize_value_function(settings.value_function)
      },
      intent_merge_threshold: mn.intent_merge_threshold,
      intent_identity_threshold: mn.intent_identity_threshold,
      refinement_threshold: mn.refinement_threshold,
      refinement_budget: mn.refinement_budget,
      plateau_delta: mn.plateau_delta,
      episodic_validation: %{
        validation_threshold: ev.validation_threshold,
        orphan_penalty: ev.orphan_penalty,
        weak_grounding_penalty: ev.weak_grounding_penalty
      },
      session: %{
        auto_commit: mn.auto_commit,
        flush_timeout_ms: mn.flush_timeout_ms,
        session_timeout_ms: mn.session_timeout_ms
      },
      trace_verbosity: String.to_atom(mn.trace_verbosity)
    }

    if Keyword.get(opts, :skip_profile, false) do
      base
    else
      maybe_put_extraction_profile(base, mn.extraction_profile)
    end
  end

  defp maybe_put_profile_struct(config, nil), do: config

  defp maybe_put_profile_struct(config, %Mnemosyne.ExtractionProfile{} = profile),
    do: Map.put(config, :extraction_profile, profile)

  @spec maintenance_opts(t()) :: keyword()
  def maintenance_opts(%__MODULE__{mnemosyne: mn}) do
    [
      consolidation_threshold: mn.consolidation_threshold,
      decay_threshold: mn.decay_threshold
    ]
  end

  @spec llm_provider_options(keyword()) :: [String.t()]
  def llm_provider_options(opts \\ []), do: provider_options(:llm, opts)

  @spec embedding_provider_options(keyword()) :: [String.t()]
  def embedding_provider_options(opts \\ []), do: provider_options(:embedding, opts)

  @spec model_options(String.t() | atom() | nil, :llm | :embedding, keyword()) :: [String.t()]
  def model_options(provider, kind, opts \\ [])
  def model_options(nil, _kind, _opts), do: []
  def model_options("", _kind, _opts), do: []
  def model_options("bumblebee", :embedding, _opts), do: [@default_bumblebee_embedding_model]
  def model_options("bumblebee", :llm, _opts), do: []

  def model_options(provider, kind, opts) do
    models_source = Keyword.get(opts, :models_source, &default_models_source/1)

    provider
    |> provider_to_atom()
    |> models_source.()
    |> Enum.filter(&keep_model?(&1, kind))
    |> Enum.map(&model_name/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parsed_config(source) do
    embeddings_provider =
      pick(
        source,
        ["embeddings", :embeddings, "provider", :provider],
        @default_embeddings["provider"]
      )

    %{
      paths: %{
        memory: pick(source, ["paths", :paths, "memory", :memory], @default_paths["memory"])
      },
      llm: %{
        provider: pick(source, ["llm", :llm, "provider", :provider], @default_llm["provider"]),
        model: pick(source, ["llm", :llm, "model", :model], @default_llm["model"])
      },
      embeddings: %{
        provider: embeddings_provider,
        model:
          pick(
            source,
            ["embeddings", :embeddings, "model", :model],
            default_embedding_model(embeddings_provider)
          )
      },
      server: %{
        host: pick(source, ["server", :server, "host", :host], @default_server["host"]),
        port:
          normalize_port(
            pick_raw(source, ["server", :server, "port", :port], @default_server["port"])
          )
      },
      mnemosyne: %{
        intent_merge_threshold:
          normalize_float(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "intent_merge_threshold", :intent_merge_threshold],
              @default_mnemosyne["intent_merge_threshold"]
            )
          ),
        intent_identity_threshold:
          normalize_float(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "intent_identity_threshold", :intent_identity_threshold],
              @default_mnemosyne["intent_identity_threshold"]
            )
          ),
        refinement_threshold:
          normalize_float(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "refinement_threshold", :refinement_threshold],
              @default_mnemosyne["refinement_threshold"]
            )
          ),
        auto_commit:
          normalize_boolean(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "auto_commit", :auto_commit],
              @default_mnemosyne["auto_commit"]
            )
          ),
        flush_timeout_ms:
          normalize_positive_integer(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "flush_timeout_ms", :flush_timeout_ms],
              @default_mnemosyne["flush_timeout_ms"]
            ),
            @default_mnemosyne["flush_timeout_ms"]
          ),
        session_timeout_ms:
          normalize_positive_integer(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "session_timeout_ms", :session_timeout_ms],
              @default_mnemosyne["session_timeout_ms"]
            ),
            @default_mnemosyne["session_timeout_ms"]
          ),
        trace_verbosity:
          normalize_trace_verbosity(
            pick(
              source,
              ["mnemosyne", :mnemosyne, "trace_verbosity", :trace_verbosity],
              @default_mnemosyne["trace_verbosity"]
            )
          ),
        refinement_budget:
          normalize_non_negative_integer(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "refinement_budget", :refinement_budget],
              @default_mnemosyne["refinement_budget"]
            ),
            @default_mnemosyne["refinement_budget"]
          ),
        plateau_delta:
          normalize_float(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "plateau_delta", :plateau_delta],
              @default_mnemosyne["plateau_delta"]
            )
          ),
        extraction_profile:
          normalize_extraction_profile(
            pick(
              source,
              ["mnemosyne", :mnemosyne, "extraction_profile", :extraction_profile],
              @default_mnemosyne["extraction_profile"]
            )
          ),
        consolidation_threshold:
          normalize_float(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "consolidation_threshold", :consolidation_threshold],
              @default_mnemosyne["consolidation_threshold"]
            )
          ),
        decay_threshold:
          normalize_float(
            pick_raw(
              source,
              ["mnemosyne", :mnemosyne, "decay_threshold", :decay_threshold],
              @default_mnemosyne["decay_threshold"]
            )
          )
      },
      episodic_validation: %{
        validation_threshold:
          normalize_float(
            pick_raw(
              source,
              [
                "episodic_validation",
                :episodic_validation,
                "validation_threshold",
                :validation_threshold
              ],
              @default_episodic_validation["validation_threshold"]
            )
          ),
        orphan_penalty:
          normalize_float(
            pick_raw(
              source,
              [
                "episodic_validation",
                :episodic_validation,
                "orphan_penalty",
                :orphan_penalty
              ],
              @default_episodic_validation["orphan_penalty"]
            )
          ),
        weak_grounding_penalty:
          normalize_float(
            pick_raw(
              source,
              [
                "episodic_validation",
                :episodic_validation,
                "weak_grounding_penalty",
                :weak_grounding_penalty
              ],
              @default_episodic_validation["weak_grounding_penalty"]
            )
          )
      },
      summaries: %{
        enabled:
          normalize_boolean(
            pick_raw(
              source,
              ["summaries", :summaries, "enabled", :enabled],
              @default_summaries["enabled"]
            )
          ),
        hot_tags_k:
          normalize_positive_integer(
            pick_raw(
              source,
              ["summaries", :summaries, "hot_tags_k", :hot_tags_k],
              @default_summaries["hot_tags_k"]
            ),
            @default_summaries["hot_tags_k"]
          ),
        cluster_regen_memory_threshold:
          normalize_positive_integer(
            pick_raw(
              source,
              [
                "summaries",
                :summaries,
                "cluster_regen_memory_threshold",
                :cluster_regen_memory_threshold
              ],
              @default_summaries["cluster_regen_memory_threshold"]
            ),
            @default_summaries["cluster_regen_memory_threshold"]
          ),
        cluster_regen_idle_seconds:
          normalize_positive_integer(
            pick_raw(
              source,
              [
                "summaries",
                :summaries,
                "cluster_regen_idle_seconds",
                :cluster_regen_idle_seconds
              ],
              @default_summaries["cluster_regen_idle_seconds"]
            ),
            @default_summaries["cluster_regen_idle_seconds"]
          ),
        principal_regen_debounce_seconds:
          normalize_positive_integer(
            pick_raw(
              source,
              [
                "summaries",
                :summaries,
                "principal_regen_debounce_seconds",
                :principal_regen_debounce_seconds
              ],
              @default_summaries["principal_regen_debounce_seconds"]
            ),
            @default_summaries["principal_regen_debounce_seconds"]
          ),
        session_primer_recent_count:
          normalize_positive_integer(
            pick_raw(
              source,
              [
                "summaries",
                :summaries,
                "session_primer_recent_count",
                :session_primer_recent_count
              ],
              @default_summaries["session_primer_recent_count"]
            ),
            @default_summaries["session_primer_recent_count"]
          )
      },
      overrides: parse_overrides(source),
      value_function: parse_value_function(source)
    }
  end

  defp parse_overrides(source) do
    raw = fetch_map(source, "overrides", :overrides)

    Enum.reduce(@pipeline_steps, %{}, fn step, acc ->
      step_raw = fetch_map(raw, step, String.to_atom(step))
      opts_raw = fetch_map(step_raw, "opts", :opts)

      temperature_raw =
        fetch_any(step_raw, "temperature", :temperature) ||
          fetch_any(opts_raw, "temperature", :temperature)

      max_tokens_raw =
        fetch_any(step_raw, "max_tokens", :max_tokens) ||
          fetch_any(opts_raw, "max_tokens", :max_tokens)

      entry = %{
        model: normalize_optional_string(fetch_any(step_raw, "model", :model)),
        temperature: normalize_optional_float(temperature_raw),
        max_tokens: normalize_optional_positive_integer(max_tokens_raw)
      }

      Map.put(acc, step, entry)
    end)
  end

  defp parse_value_function(source) do
    vf = fetch_map(source, "value_function", :value_function)
    nested_params = fetch_map(vf, "params", :params)

    Enum.reduce(@node_types, %{}, fn type, acc ->
      defaults = Map.fetch!(@vf_param_defaults, type)

      incoming =
        merge_type_params(
          fetch_map(vf, type, String.to_atom(type)),
          fetch_map(nested_params, type, String.to_atom(type))
        )

      entry =
        Enum.reduce(@vf_param_keys, %{}, fn key, entry_acc ->
          default_value = Map.fetch!(defaults, key)
          raw = fetch_any(incoming, key, String.to_atom(key), default_value)
          Map.put(entry_acc, key, normalize_vf_param(key, raw, default_value))
        end)

      Map.put(acc, type, entry)
    end)
  end

  defp merge_type_params(flat, nested) when map_size(flat) == 0, do: nested
  defp merge_type_params(flat, nested), do: Map.merge(nested, flat)

  defp fetch_any(source, key_string, key_atom) when is_map(source) do
    cond do
      Map.has_key?(source, key_string) -> Map.get(source, key_string)
      Map.has_key?(source, key_atom) -> Map.get(source, key_atom)
      true -> nil
    end
  end

  defp fetch_any(_source, _key_string, _key_atom), do: nil

  defp fetch_any(source, key_string, key_atom, default) do
    case fetch_any(source, key_string, key_atom) do
      nil -> default
      value -> value
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_optional_float(nil), do: nil
  defp normalize_optional_float(value) when is_float(value), do: value
  defp normalize_optional_float(value) when is_integer(value), do: value / 1

  defp normalize_optional_float(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        case Float.parse(trimmed) do
          {float, _} -> float
          :error -> nil
        end
    end
  end

  defp normalize_optional_float(_), do: nil

  defp normalize_optional_positive_integer(nil), do: nil

  defp normalize_optional_positive_integer(value) when is_integer(value) do
    if value > 0, do: value, else: nil
  end

  defp normalize_optional_positive_integer(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {int, ""} when int > 0 -> int
          _ -> nil
        end
    end
  end

  defp normalize_optional_positive_integer(_), do: nil

  defp normalize_vf_param(key, value, default) when key in @vf_integer_keys do
    case normalize_optional_positive_integer(value) do
      nil -> default
      int -> int
    end
  end

  defp normalize_vf_param(_key, value, default) do
    case normalize_optional_float(value) do
      nil -> default
      float -> float
    end
  end

  defp pick(source, [section_key_string, section_key_atom, key_string, key_atom], default) do
    source
    |> pick_raw([section_key_string, section_key_atom, key_string, key_atom], default)
    |> normalize_string(default)
  end

  defp pick_raw(source, [section_key_string, section_key_atom, key_string, key_atom], default) do
    source
    |> fetch_map(section_key_string, section_key_atom)
    |> fetch_value(key_string, key_atom, default)
  end

  defp fetch_map(source, key_string, key_atom) do
    Map.get(source, key_string) || Map.get(source, key_atom) || %{}
  end

  defp fetch_value(section, key_string, key_atom, default) when is_map(section) do
    cond do
      Map.has_key?(section, key_string) -> Map.get(section, key_string)
      Map.has_key?(section, key_atom) -> Map.get(section, key_atom)
      true -> default
    end
  end

  defp fetch_value(_section, _key_string, _key_atom, default), do: default

  defp normalize_string(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value, default), do: default

  defp default_embedding_model("bumblebee"), do: @default_bumblebee_embedding_model
  defp default_embedding_model(_provider), do: @default_embeddings["model"]

  defp normalize_port(port) when is_integer(port) and port > 0, do: port

  defp normalize_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, ""} when int > 0 -> int
      _ -> @default_server["port"]
    end
  end

  defp normalize_port(_), do: @default_server["port"]

  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value / 1

  defp normalize_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp normalize_float(_), do: 0.0

  defp normalize_boolean(value) when is_boolean(value), do: value
  defp normalize_boolean("true"), do: true
  defp normalize_boolean("false"), do: false
  defp normalize_boolean(_), do: true

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_positive_integer(_, default), do: default

  defp normalize_trace_verbosity(value) when value in ~w(summary detailed), do: value
  defp normalize_trace_verbosity(_), do: "summary"

  @extraction_profiles ~w(none coding research customer_support)

  defp normalize_extraction_profile(value) when value in @extraction_profiles, do: value
  defp normalize_extraction_profile(_), do: "none"

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int >= 0 -> int
      _ -> default
    end
  end

  defp normalize_non_negative_integer(_, default), do: default

  defp maybe_put_extraction_profile(config, "none"), do: config

  defp maybe_put_extraction_profile(config, "coding"),
    do: Map.put(config, :extraction_profile, Mnemosyne.ExtractionProfile.coding())

  defp maybe_put_extraction_profile(config, "research"),
    do: Map.put(config, :extraction_profile, Mnemosyne.ExtractionProfile.research())

  defp maybe_put_extraction_profile(config, "customer_support"),
    do: Map.put(config, :extraction_profile, Mnemosyne.ExtractionProfile.customer_support())

  defp maybe_put_extraction_profile(config, _), do: config

  defp validate(parsed, opts) do
    llm_resolver = Keyword.get(opts, :llm_resolver, &default_llm_resolver/1)
    embedding_resolver = Keyword.get(opts, :embedding_resolver, &default_embedding_resolver/1)
    os_type = Keyword.get(opts, :os_type, &:os.type/0)

    []
    |> validate_required(parsed.llm.provider, "llm.provider")
    |> validate_required(parsed.embeddings.provider, "embeddings.provider")
    |> validate_required(parsed.llm.model, "llm.model")
    |> validate_required(parsed.embeddings.model, "embeddings.model")
    |> validate_model_spec(parsed.llm, llm_resolver, "llm.model")
    |> validate_embedding_model_spec(
      parsed.embeddings,
      embedding_resolver,
      os_type,
      "embeddings.model"
    )
  end

  defp validate_required(issues, value, path) do
    if is_binary(value) and value != "" do
      issues
    else
      [issue(path, "must be present") | issues]
    end
  end

  defp validate_model_spec(issues, %{provider: provider, model: model} = config, resolver, path) do
    if present?(provider) and present?(model) do
      case resolver.(qualified_model(config)) do
        {:ok, _} ->
          issues

        {:error, _reason} ->
          [issue(path, "unsupported model specification #{qualified_model(config)}") | issues]
      end
    else
      issues
    end
  end

  defp validate_embedding_model_spec(issues, %{provider: "bumblebee"}, _resolver, os_type, path) do
    case os_type.() do
      {:win32, _} ->
        [issue(path, "bumblebee embeddings are not supported on Windows") | issues]

      _ ->
        issues
    end
  end

  defp validate_embedding_model_spec(issues, config, resolver, _os_type, path) do
    validate_model_spec(issues, config, resolver, path)
  end

  defp issue(path, message), do: %{path: path, message: message}

  defp error_message(error) do
    if is_exception(error), do: Exception.message(error), else: inspect(error)
  end

  defp qualified_model(%{provider: provider, model: model}) do
    if String.contains?(model, ":") do
      model
    else
      provider <> ":" <> model
    end
  end

  defp to_toml_map(parsed) do
    %{
      "paths" => %{"memory" => parsed.paths.memory},
      "llm" => %{"provider" => parsed.llm.provider, "model" => parsed.llm.model},
      "embeddings" => %{
        "provider" => parsed.embeddings.provider,
        "model" => parsed.embeddings.model
      },
      "server" => %{"host" => parsed.server.host, "port" => parsed.server.port},
      "mnemosyne" => %{
        "intent_merge_threshold" => parsed.mnemosyne.intent_merge_threshold,
        "intent_identity_threshold" => parsed.mnemosyne.intent_identity_threshold,
        "refinement_threshold" => parsed.mnemosyne.refinement_threshold,
        "refinement_budget" => parsed.mnemosyne.refinement_budget,
        "plateau_delta" => parsed.mnemosyne.plateau_delta,
        "extraction_profile" => parsed.mnemosyne.extraction_profile,
        "consolidation_threshold" => parsed.mnemosyne.consolidation_threshold,
        "decay_threshold" => parsed.mnemosyne.decay_threshold,
        "auto_commit" => parsed.mnemosyne.auto_commit,
        "flush_timeout_ms" => parsed.mnemosyne.flush_timeout_ms,
        "session_timeout_ms" => parsed.mnemosyne.session_timeout_ms,
        "trace_verbosity" => parsed.mnemosyne.trace_verbosity
      },
      "episodic_validation" => %{
        "validation_threshold" => parsed.episodic_validation.validation_threshold,
        "orphan_penalty" => parsed.episodic_validation.orphan_penalty,
        "weak_grounding_penalty" => parsed.episodic_validation.weak_grounding_penalty
      },
      "summaries" => %{
        "enabled" => parsed.summaries.enabled,
        "hot_tags_k" => parsed.summaries.hot_tags_k,
        "cluster_regen_memory_threshold" => parsed.summaries.cluster_regen_memory_threshold,
        "cluster_regen_idle_seconds" => parsed.summaries.cluster_regen_idle_seconds,
        "principal_regen_debounce_seconds" => parsed.summaries.principal_regen_debounce_seconds,
        "session_primer_recent_count" => parsed.summaries.session_primer_recent_count
      },
      "overrides" => overrides_to_toml(parsed.overrides),
      "value_function" => %{"params" => value_function_to_toml(parsed.value_function)}
    }
  end

  defp overrides_to_toml(overrides) do
    Enum.reduce(overrides, %{}, fn {step, entry}, acc ->
      step_map = override_entry_to_toml(entry)

      if map_size(step_map) == 0 do
        acc
      else
        Map.put(acc, step, step_map)
      end
    end)
  end

  defp override_entry_to_toml(entry) do
    model_map = if is_binary(entry.model), do: %{"model" => entry.model}, else: %{}

    opts_map =
      []
      |> then(fn acc ->
        if is_number(entry.temperature),
          do: [{"temperature", entry.temperature} | acc],
          else: acc
      end)
      |> then(fn acc ->
        if is_integer(entry.max_tokens),
          do: [{"max_tokens", entry.max_tokens} | acc],
          else: acc
      end)
      |> Map.new()

    case opts_map do
      map when map_size(map) == 0 -> model_map
      map -> Map.put(model_map, "opts", map)
    end
  end

  defp value_function_to_toml(value_function) do
    Enum.reduce(@node_types, %{}, fn type, acc ->
      Map.put(acc, type, value_function_type_to_toml(value_function, type))
    end)
  end

  defp value_function_type_to_toml(value_function, type) do
    case Map.get(value_function, type) do
      nil -> Map.fetch!(@vf_param_defaults, type)
      params -> Map.new(@vf_param_keys, fn key -> {key, Map.fetch!(params, key)} end)
    end
  end

  defp default_toml! do
    TomlElixir.encode!(%{
      "paths" => %{"memory" => @default_paths["memory"]},
      "llm" => @default_llm,
      "embeddings" => @default_embeddings,
      "server" => @default_server,
      "mnemosyne" => @default_mnemosyne,
      "episodic_validation" => @default_episodic_validation,
      "summaries" => @default_summaries,
      "overrides" => @default_overrides,
      "value_function" => %{"params" => @vf_param_defaults}
    })
  end

  defp provider_options(kind, opts) do
    providers_source = Keyword.get(opts, :providers_source, &default_providers_source/0)
    models_source = Keyword.get(opts, :models_source, &default_models_source/1)
    os_type = Keyword.get(opts, :os_type, &:os.type/0)

    providers_source.()
    |> Enum.map(&provider_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&provider_supported?(&1, kind, models_source))
    |> maybe_add_bumblebee(kind, os_type)
    |> Enum.sort()
  end

  defp provider_supported?(provider, :llm, models_source) do
    provider
    |> provider_to_atom()
    |> models_source.()
    |> Enum.any?()
  end

  defp provider_supported?(provider, :embedding, models_source) do
    provider
    |> provider_to_atom()
    |> models_source.()
    |> Enum.any?(&embedding_model?/1)
  end

  defp embedding_model?(model) do
    modalities = Map.get(model, :modalities) || %{}
    outputs = Map.get(modalities, :output, [])

    :embedding in outputs
  end

  defp keep_model?(model, :embedding), do: embedding_model?(model)
  defp keep_model?(model, :llm), do: not embedding_model?(model)

  defp model_name(%{id: id}) when is_binary(id) and id != "", do: id
  defp model_name(%{id: id}) when is_atom(id) and not is_nil(id), do: Atom.to_string(id)
  defp model_name(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp model_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp model_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp model_name(_), do: nil

  defp maybe_add_bumblebee(providers, :embedding, os_type) do
    case os_type.() do
      {:win32, _} -> providers
      _ -> Enum.uniq(["bumblebee" | providers])
    end
  end

  defp maybe_add_bumblebee(providers, _kind, _os_type), do: providers

  defp provider_name(%{id: id}), do: provider_name(id)
  defp provider_name(id) when is_atom(id), do: Atom.to_string(id)
  defp provider_name(id) when is_binary(id) and id != "", do: id
  defp provider_name(_), do: nil

  defp provider_to_atom(provider) when is_binary(provider), do: String.to_atom(provider)
  defp provider_to_atom(provider) when is_atom(provider), do: provider

  defp embedding_runtime(%{provider: "bumblebee", model: model}) do
    %{
      adapter: Gingko.Embeddings.LazyBumblebeeEmbedding,
      config: %{
        model: model,
        opts: %{
          serving: Gingko.Embeddings.BumblebeeServing.name(),
          model: model
        }
      }
    }
  end

  defp embedding_runtime(embeddings) do
    %{
      adapter: Mnemosyne.Adapters.SycophantEmbedding,
      config: %{model: qualified_model(embeddings), opts: %{}}
    }
  end

  defp atomize_overrides(overrides) when is_map(overrides) do
    Enum.reduce(overrides, %{}, fn {step, entry}, acc ->
      opts = atomize_override_opts(entry)

      payload =
        cond do
          is_binary(entry.model) and map_size(opts) > 0 ->
            %{model: entry.model, opts: opts}

          is_binary(entry.model) ->
            %{model: entry.model, opts: %{}}

          map_size(opts) > 0 ->
            %{opts: opts}

          true ->
            nil
        end

      case payload do
        nil -> acc
        map -> Map.put(acc, String.to_existing_atom(step), map)
      end
    end)
  end

  defp atomize_override_opts(entry) do
    %{}
    |> maybe_put(:temperature, entry.temperature, &is_number/1)
    |> maybe_put(:max_tokens, entry.max_tokens, &is_integer/1)
  end

  defp maybe_put(map, key, value, guard) do
    if guard.(value), do: Map.put(map, key, value), else: map
  end

  defp atomize_value_function(value_function) when is_map(value_function) do
    Enum.reduce(value_function, %{}, fn {type, params}, acc ->
      atom_type = String.to_existing_atom(type)

      atom_params =
        Enum.reduce(@vf_param_keys, %{}, fn key, param_acc ->
          Map.put(param_acc, String.to_existing_atom(key), Map.fetch!(params, key))
        end)

      Map.put(acc, atom_type, atom_params)
    end)
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp default_llm_resolver(spec), do: Sycophant.ModelResolver.resolve(spec)
  defp default_embedding_resolver(spec), do: Sycophant.ModelResolver.resolve_embedding(spec)

  defp default_providers_source do
    if Code.ensure_loaded?(LLMDB) and function_exported?(LLMDB, :providers, 0) do
      LLMDB.providers()
    else
      []
    end
  rescue
    _ -> []
  end

  defp default_models_source(provider) do
    if Code.ensure_loaded?(LLMDB) and function_exported?(LLMDB, :models, 1) do
      LLMDB.models(provider)
    else
      []
    end
  rescue
    _ -> []
  end
end
