defmodule GingkoWeb.SetupLive do
  @moduledoc false

  use GingkoWeb, :live_view

  alias Gingko.Settings
  alias Phoenix.Component

  @tabs [
    %{id: "general", label: "General"},
    %{id: "models", label: "Models"},
    %{id: "memory_engine", label: "Memory Engine"},
    %{id: "validation", label: "Retrieval Validation"},
    %{id: "summaries", label: "Summaries"},
    %{id: "overrides", label: "Pipeline Overrides"},
    %{id: "value_function", label: "Value Function"}
  ]
  @tab_ids Enum.map(@tabs, & &1.id)

  @vf_param_meta [
    {"threshold", "Min score for inclusion"},
    {"top_k", "Max nodes kept"},
    {"lambda", "Decay rate"},
    {"k", "Hop limit"},
    {"base_floor", "Min retained score"},
    {"beta", "Recency weight"}
  ]

  @extraction_profile_options [
    {"None", "none"},
    {"Coding", "coding"},
    {"Research", "research"},
    {"Customer support", "customer_support"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Setup",
       settings: nil,
       form: nil,
       llm_providers: [],
       embedding_providers: [],
       llm_models: [],
       embedding_models: [],
       tabs: @tabs,
       active_tab: "general",
       pipeline_steps: Settings.pipeline_steps(),
       node_types: Settings.node_types(),
       vf_param_meta: @vf_param_meta
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    opts = settings_opts()
    settings = Settings.load(opts)

    {:noreply,
     assign(socket,
       settings: settings,
       form: settings_form(settings),
       llm_providers: Settings.llm_provider_options(opts),
       embedding_providers: Settings.embedding_provider_options(opts),
       llm_models: Settings.model_options(settings.llm.provider, :llm, opts),
       embedding_models: Settings.model_options(settings.embeddings.provider, :embedding, opts)
     )}
  end

  @impl true
  def handle_event("validate", %{"settings" => attrs}, socket) do
    opts = settings_opts()

    attrs =
      attrs
      |> maybe_clear_model("llm", socket.assigns.settings.llm.provider)
      |> maybe_clear_model("embeddings", socket.assigns.settings.embeddings.provider)

    settings = Settings.preview(attrs, opts)

    {:noreply,
     socket
     |> assign(:settings, settings)
     |> assign(:form, settings_form(attrs))
     |> assign(:llm_models, Settings.model_options(settings.llm.provider, :llm, opts))
     |> assign(
       :embedding_models,
       Settings.model_options(settings.embeddings.provider, :embedding, opts)
     )}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in @tab_ids do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("select_tab", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save", %{"settings" => attrs}, socket) do
    case Settings.save(attrs, settings_opts()) do
      {:ok, settings} ->
        sync_runtime_settings(settings)
        socket = assign(socket, settings: settings, form: settings_form(settings))

        if settings.ready? do
          {:noreply,
           socket
           |> put_flash(:info, "Settings saved")
           |> push_navigate(to: ~p"/projects")}
        else
          {:noreply, put_flash(socket, :info, "Settings saved, but setup is still incomplete.")}
        end

      {:error, error} ->
        {:noreply, put_flash(socket, :error, "Could not save settings: #{inspect(error)}")}
    end
  end

  @impl true
  def render(%{settings: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={assigns[:page_title]}>
      <section class="mx-auto max-w-4xl p-6">
        <p>Loading setup...</p>
      </section>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={assigns[:page_title]}>
      <section class="mx-auto w-full max-w-4xl p-6">
        <div class="rounded-2xl border border-base-300 bg-base-100 p-6">
          <.header>
            Setup Required
            <:subtitle>Configure Gingko without editing Elixir config files.</:subtitle>
          </.header>

          <div class="mt-4 flex flex-wrap gap-2 text-sm">
            <span class="rounded-full border border-base-300 px-3 py-1">
              Home: {@settings.home}
            </span>
            <span class="rounded-full border border-base-300 px-3 py-1">
              Status: {if(@settings.ready?, do: "ready", else: "setup required")}
            </span>
          </div>

          <div
            :if={not Enum.empty?(@settings.issues)}
            class="alert alert-warning mt-4 rounded-xl"
          >
            <div>
              <p class="text-sm font-semibold">Missing configuration</p>
              <ul class="mt-2 space-y-1 text-sm">
                <li :for={issue <- @settings.issues}>
                  <span class="font-mono">{issue.path}</span>: {issue.message}
                </li>
              </ul>
            </div>
          </div>

          <.form
            id="settings-form"
            for={@form}
            phx-change="validate"
            phx-submit="save"
            class="mt-6 space-y-6"
          >
            <div role="tablist" class="tabs tabs-lifted tabs-lg">
              <button
                :for={tab <- @tabs}
                type="button"
                role="tab"
                phx-click="select_tab"
                phx-value-tab={tab.id}
                class={["tab", tab.id == @active_tab && "tab-active font-semibold"]}
              >
                {tab.label}
              </button>
            </div>

            <div class={[tab_panel_classes("general", @active_tab)]}>
              <.general_panel form={@form} />
            </div>

            <div class={[tab_panel_classes("models", @active_tab)]}>
              <.models_panel
                form={@form}
                settings={@settings}
                llm_providers={@llm_providers}
                embedding_providers={@embedding_providers}
                llm_models={@llm_models}
                embedding_models={@embedding_models}
              />
            </div>

            <div class={[tab_panel_classes("memory_engine", @active_tab)]}>
              <.memory_engine_panel form={@form} />
            </div>

            <div class={[tab_panel_classes("validation", @active_tab)]}>
              <.validation_panel form={@form} />
            </div>

            <div class={[tab_panel_classes("summaries", @active_tab)]}>
              <.summaries_panel form={@form} />
            </div>

            <div class={[tab_panel_classes("overrides", @active_tab)]}>
              <.overrides_panel form={@form} pipeline_steps={@pipeline_steps} />
            </div>

            <div class={[tab_panel_classes("value_function", @active_tab)]}>
              <.value_function_panel
                form={@form}
                node_types={@node_types}
                vf_param_meta={@vf_param_meta}
              />
            </div>

            <div class="flex items-center justify-end gap-4 pt-2">
              <button class="btn btn-primary" type="submit">Save Settings</button>
            </div>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp tab_panel_classes(tab_id, active_tab) do
    [
      "rounded-xl border border-base-300 bg-base-100 p-5 space-y-6",
      tab_id != active_tab && "hidden"
    ]
  end

  attr :form, :any, required: true

  defp general_panel(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
        Paths
      </h2>
      <.inputs_for :let={paths_form} field={@form[:paths]}>
        <.input field={paths_form[:memory]} type="text" label="Memory directory" />
      </.inputs_for>
    </section>

    <section class="space-y-3">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
        Server
      </h2>
      <.inputs_for :let={server_form} field={@form[:server]}>
        <div class="grid gap-4 md:grid-cols-2">
          <.input field={server_form[:host]} type="text" label="Host" />
          <.input field={server_form[:port]} type="number" label="Port" />
        </div>
      </.inputs_for>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :settings, :any, required: true
  attr :llm_providers, :list, required: true
  attr :embedding_providers, :list, required: true
  attr :llm_models, :list, required: true
  attr :embedding_models, :list, required: true

  defp models_panel(assigns) do
    ~H"""
    <section class="grid gap-6 md:grid-cols-2">
      <.inputs_for :let={llm_form} field={@form[:llm]}>
        <div class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            LLM
          </h2>
          <.combobox
            field={llm_form[:provider]}
            label="Provider"
            options={@llm_providers}
            placeholder="Select or search a provider"
          />
          <.combobox
            field={llm_form[:model]}
            label="Model"
            options={@llm_models}
            placeholder={model_placeholder(@llm_models)}
          />
        </div>
      </.inputs_for>

      <.inputs_for :let={embedding_form} field={@form[:embeddings]}>
        <div class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            Embeddings
          </h2>
          <.combobox
            field={embedding_form[:provider]}
            label="Provider"
            options={@embedding_providers}
            placeholder="Select or search a provider"
          />
          <.combobox
            field={embedding_form[:model]}
            label="Model"
            options={@embedding_models}
            placeholder={model_placeholder(@embedding_models)}
          />
          <p
            :if={@settings.embeddings.provider == "bumblebee"}
            class="text-sm text-base-content/70"
          >
            Defaults to <code>intfloat/e5-base-v2</code> when left blank.
          </p>
          <div
            :if={@settings.embeddings.provider == "bumblebee"}
            class="rounded-xl border border-base-300 bg-base-200 p-3 text-sm"
          >
            Gingko will download and start this embedding model automatically.
          </div>
        </div>
      </.inputs_for>
    </section>
    """
  end

  defp model_placeholder([]), do: "Pick a provider first"
  defp model_placeholder(_), do: "Select or search a model"

  attr :form, :any, required: true

  defp memory_engine_panel(assigns) do
    assigns = assign(assigns, :profile_options, @extraction_profile_options)

    ~H"""
    <section class="space-y-4">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
        Memory Engine
      </h2>
      <.inputs_for :let={mn_form} field={@form[:mnemosyne]}>
        <div class="space-y-5">
          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/60 mb-2">
              Intent matching
            </h3>
            <div class="grid gap-4 md:grid-cols-3">
              <.input
                field={mn_form[:intent_merge_threshold]}
                type="number"
                label="Intent merge threshold"
                step="0.01"
                min="0"
                max="1"
              />
              <.input
                field={mn_form[:intent_identity_threshold]}
                type="number"
                label="Intent identity threshold"
                step="0.01"
                min="0"
                max="1"
              />
              <.input
                field={mn_form[:refinement_threshold]}
                type="number"
                label="Refinement threshold"
                step="0.01"
                min="0"
                max="1"
              />
            </div>
          </div>

          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/60 mb-2">
              Refinement
            </h3>
            <div class="grid gap-4 md:grid-cols-3">
              <div>
                <.input
                  field={mn_form[:refinement_budget]}
                  type="number"
                  label="Refinement budget"
                  min="0"
                />
                <p class="mt-1 text-xs text-base-content/60">
                  Max LLM refinement calls per recall. Default 1.
                </p>
              </div>
              <div>
                <.input
                  field={mn_form[:plateau_delta]}
                  type="number"
                  label="Plateau delta"
                  step="0.01"
                  min="0"
                  max="1"
                />
                <p class="mt-1 text-xs text-base-content/60">
                  Lower = refine more aggressively. Default 0.05.
                </p>
              </div>
              <div>
                <.input
                  field={mn_form[:extraction_profile]}
                  type="select"
                  label="Extraction profile"
                  options={@profile_options}
                />
                <p class="mt-1 text-xs text-base-content/60">
                  Domain-specific prompt overlays.
                </p>
              </div>
            </div>
          </div>

          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/60 mb-2">
              Maintenance
            </h3>
            <div class="grid gap-4 md:grid-cols-2">
              <div>
                <.input
                  field={mn_form[:consolidation_threshold]}
                  type="number"
                  label="Consolidation threshold"
                  step="0.01"
                  min="0"
                  max="1"
                />
                <p class="mt-1 text-xs text-base-content/60">
                  Cosine similarity above which semantic nodes merge. Default 0.85.
                </p>
              </div>
              <div>
                <.input
                  field={mn_form[:decay_threshold]}
                  type="number"
                  label="Decay threshold"
                  step="0.01"
                  min="0"
                  max="1"
                />
                <p class="mt-1 text-xs text-base-content/60">
                  Minimum decay score to survive pruning. Default 0.1.
                </p>
              </div>
            </div>
          </div>

          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/60 mb-2">
              Sessions
            </h3>
            <div class="grid gap-4 md:grid-cols-3">
              <.input
                field={mn_form[:auto_commit]}
                type="checkbox"
                label="Auto-commit sessions"
              />
              <.input
                field={mn_form[:flush_timeout_ms]}
                type="number"
                label="Flush timeout (ms)"
                min="1000"
              />
              <.input
                field={mn_form[:session_timeout_ms]}
                type="number"
                label="Session timeout (ms)"
                min="1000"
              />
            </div>
          </div>

          <div>
            <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/60 mb-2">
              Telemetry
            </h3>
            <div class="grid gap-4 md:grid-cols-3">
              <.input
                field={mn_form[:trace_verbosity]}
                type="select"
                label="Trace verbosity"
                options={[{"Summary", "summary"}, {"Detailed", "detailed"}]}
              />
            </div>
          </div>
        </div>
      </.inputs_for>
    </section>
    """
  end

  attr :form, :any, required: true

  defp validation_panel(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
        Episodic Validation
      </h2>
      <p class="text-sm text-base-content/70">
        Scores how well abstract nodes are grounded in source evidence. Lower thresholds
        and higher penalties prune weakly grounded nodes more aggressively.
      </p>
      <.inputs_for :let={ev_form} field={@form[:episodic_validation]}>
        <div class="grid gap-4 md:grid-cols-3">
          <div>
            <.input
              field={ev_form[:validation_threshold]}
              type="number"
              label="Validation threshold"
              step="0.01"
              min="0"
              max="1"
            />
            <p class="mt-1 text-xs text-base-content/60">
              Min grounding similarity. Default 0.3.
            </p>
          </div>
          <div>
            <.input
              field={ev_form[:orphan_penalty]}
              type="number"
              label="Orphan penalty"
              step="0.01"
              min="0"
              max="1"
            />
            <p class="mt-1 text-xs text-base-content/60">
              Penalty for nodes with no episodic provenance. Default 0.3.
            </p>
          </div>
          <div>
            <.input
              field={ev_form[:weak_grounding_penalty]}
              type="number"
              label="Weak grounding penalty"
              step="0.01"
              min="0"
              max="1"
            />
            <p class="mt-1 text-xs text-base-content/60">
              Penalty for low embedding similarity to sources. Default 0.1.
            </p>
          </div>
        </div>
      </.inputs_for>
    </section>
    """
  end

  attr :form, :any, required: true

  defp summaries_panel(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
        Memory Summaries
      </h2>
      <.inputs_for :let={summaries_form} field={@form[:summaries]}>
        <div class="space-y-4">
          <div class="grid gap-4 md:grid-cols-2">
            <.input
              field={summaries_form[:enabled]}
              type="checkbox"
              label="Enabled"
            />
            <div>
              <.input
                field={summaries_form[:hot_tags_k]}
                type="number"
                label="Hot tags K"
                min="1"
              />
              <p class="mt-1 text-xs text-base-content/60">
                Leave blank or invalid to use default (15).
              </p>
            </div>
          </div>

          <div class="grid gap-4 md:grid-cols-2">
            <div>
              <.input
                field={summaries_form[:cluster_regen_memory_threshold]}
                type="number"
                label="Cluster regen memory threshold"
                min="1"
              />
              <p class="mt-1 text-xs text-base-content/60">
                Leave blank or invalid to use default (10).
              </p>
            </div>
            <div>
              <.input
                field={summaries_form[:cluster_regen_idle_seconds]}
                type="number"
                label="Cluster regen idle seconds"
                min="1"
              />
              <p class="mt-1 text-xs text-base-content/60">
                Leave blank or invalid to use default (1800).
              </p>
            </div>
          </div>

          <div class="grid gap-4 md:grid-cols-2">
            <div>
              <.input
                field={summaries_form[:principal_regen_debounce_seconds]}
                type="number"
                label="Principal regen debounce seconds"
                min="1"
              />
              <p class="mt-1 text-xs text-base-content/60">
                Leave blank or invalid to use default (60).
              </p>
            </div>
            <div>
              <.input
                field={summaries_form[:session_primer_recent_count]}
                type="number"
                label="Session primer recent count"
                min="1"
              />
              <p class="mt-1 text-xs text-base-content/60">
                Leave blank or invalid to use default (15).
              </p>
            </div>
          </div>
        </div>
      </.inputs_for>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :pipeline_steps, :list, required: true

  defp overrides_panel(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
        Per-step LLM overrides
      </h2>
      <p class="text-sm text-base-content/70">
        Override the default LLM model (and optionally temperature / max tokens) for individual
        pipeline steps. Leave a row blank to use the default LLM configuration for that step.
      </p>
      <.inputs_for :let={overrides_form} field={@form[:overrides]}>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Pipeline step</th>
                <th>Model</th>
                <th class="w-28">Temperature</th>
                <th class="w-28">Max tokens</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={step <- @pipeline_steps}>
                <td class="font-mono text-xs">{step}</td>
                <.inputs_for :let={step_form} field={overrides_form[step]}>
                  <td>
                    <input
                      type="text"
                      name={step_form[:model].name}
                      value={value_or_blank(step_form[:model].value)}
                      placeholder="(default)"
                      phx-debounce="blur"
                      class="input input-sm input-bordered w-full"
                    />
                  </td>
                  <td>
                    <input
                      type="number"
                      step="0.01"
                      min="0"
                      max="2"
                      name={step_form[:temperature].name}
                      value={value_or_blank(step_form[:temperature].value)}
                      phx-debounce="blur"
                      class="input input-sm input-bordered w-full"
                    />
                  </td>
                  <td>
                    <input
                      type="number"
                      min="1"
                      name={step_form[:max_tokens].name}
                      value={value_or_blank(step_form[:max_tokens].value)}
                      phx-debounce="blur"
                      class="input input-sm input-bordered w-full"
                    />
                  </td>
                </.inputs_for>
              </tr>
            </tbody>
          </table>
        </div>
      </.inputs_for>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :node_types, :list, required: true
  attr :vf_param_meta, :list, required: true

  defp value_function_panel(assigns) do
    ~H"""
    <section class="space-y-3">
      <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
        Value function parameters
      </h2>
      <p class="text-sm text-base-content/70">
        Tune per-node-type scoring parameters used by the retrieval value function. Defaults are
        tuned for a balanced mix; tighten thresholds to prune noisy matches.
      </p>
      <.inputs_for :let={vf_form} field={@form[:value_function]}>
        <div class="space-y-3">
          <details
            :for={{type, idx} <- Enum.with_index(@node_types)}
            class="collapse collapse-arrow bg-base-200 rounded-xl"
            open={idx == 0}
          >
            <summary class="collapse-title text-sm font-semibold">{type}</summary>
            <div class="collapse-content">
              <.inputs_for :let={type_form} field={vf_form[type]}>
                <div class="grid gap-4 md:grid-cols-3">
                  <div :for={{key, hint} <- @vf_param_meta}>
                    <.input
                      field={type_form[key]}
                      type="number"
                      label={key}
                      step={if key in ["top_k", "k"], do: "1", else: "0.01"}
                      min="0"
                    />
                    <p class="mt-1 text-xs text-base-content/60">{hint}</p>
                  </div>
                </div>
              </.inputs_for>
            </div>
          </details>
        </div>
      </.inputs_for>
    </section>
    """
  end

  defp value_or_blank(nil), do: ""
  defp value_or_blank(""), do: ""
  defp value_or_blank(value), do: value

  defp settings_form(%Settings{} = settings) do
    settings
    |> settings_attrs()
    |> settings_form()
  end

  defp settings_form(attrs) when is_map(attrs) do
    Component.to_form(attrs, as: :settings)
  end

  defp settings_attrs(settings) do
    %{
      "paths" => %{"memory" => settings.paths.memory},
      "llm" => %{"provider" => settings.llm.provider, "model" => settings.llm.model},
      "embeddings" => %{
        "provider" => settings.embeddings.provider,
        "model" => settings.embeddings.model
      },
      "server" => %{"host" => settings.server.host, "port" => settings.server.port},
      "mnemosyne" => %{
        "intent_merge_threshold" => settings.mnemosyne.intent_merge_threshold,
        "intent_identity_threshold" => settings.mnemosyne.intent_identity_threshold,
        "refinement_threshold" => settings.mnemosyne.refinement_threshold,
        "refinement_budget" => settings.mnemosyne.refinement_budget,
        "plateau_delta" => settings.mnemosyne.plateau_delta,
        "extraction_profile" => settings.mnemosyne.extraction_profile,
        "consolidation_threshold" => settings.mnemosyne.consolidation_threshold,
        "decay_threshold" => settings.mnemosyne.decay_threshold,
        "auto_commit" => settings.mnemosyne.auto_commit,
        "flush_timeout_ms" => settings.mnemosyne.flush_timeout_ms,
        "session_timeout_ms" => settings.mnemosyne.session_timeout_ms,
        "trace_verbosity" => settings.mnemosyne.trace_verbosity
      },
      "episodic_validation" => %{
        "validation_threshold" => settings.episodic_validation.validation_threshold,
        "orphan_penalty" => settings.episodic_validation.orphan_penalty,
        "weak_grounding_penalty" => settings.episodic_validation.weak_grounding_penalty
      },
      "summaries" => %{
        "enabled" => settings.summaries.enabled,
        "hot_tags_k" => settings.summaries.hot_tags_k,
        "cluster_regen_memory_threshold" => settings.summaries.cluster_regen_memory_threshold,
        "cluster_regen_idle_seconds" => settings.summaries.cluster_regen_idle_seconds,
        "principal_regen_debounce_seconds" => settings.summaries.principal_regen_debounce_seconds,
        "session_primer_recent_count" => settings.summaries.session_primer_recent_count
      },
      "overrides" => overrides_attrs(settings),
      "value_function" => value_function_attrs(settings)
    }
  end

  defp overrides_attrs(settings) do
    Map.new(Settings.pipeline_steps(), fn step ->
      entry = Map.get(settings.overrides, step, %{})

      {step,
       %{
         "model" => blank_if_nil(Map.get(entry, :model)),
         "temperature" => blank_if_nil(Map.get(entry, :temperature)),
         "max_tokens" => blank_if_nil(Map.get(entry, :max_tokens))
       }}
    end)
  end

  defp value_function_attrs(settings) do
    Map.new(Settings.node_types(), fn type ->
      params = Map.get(settings.value_function, type, %{})

      type_params =
        Map.new(Settings.value_function_param_keys(), fn key ->
          {key, Map.fetch!(params, key)}
        end)

      {type, type_params}
    end)
  end

  defp blank_if_nil(nil), do: ""
  defp blank_if_nil(value), do: value

  defp maybe_clear_model(attrs, section, old_provider) do
    section_attrs = Map.get(attrs, section, %{})
    new_provider = Map.get(section_attrs, "provider")

    if new_provider != old_provider do
      Map.put(attrs, section, Map.put(section_attrs, "model", ""))
    else
      attrs
    end
  end

  defp settings_opts do
    Application.get_env(:gingko, :settings_opts, [])
  end

  defp sync_runtime_settings(settings) do
    Gingko.Application.sync_runtime_settings(settings, settings_opts())
  end
end
