defmodule GingkoWeb.ProjectLive.OverlaysTabComponent do
  @moduledoc """
  Per-project extraction-overlay editor.

  Lets a project override the Mnemosyne extraction profile: pick a base
  (inherit the global profile, or start from `none`/`coding`/`research`/
  `customer_support`), set a custom `domain_context`, and override overlay
  text for individual pipeline steps.

  Saving persists the overlay, which broadcasts on `Projects.overlays_topic/0`
  and triggers `Gingko.Memory.OverlayReloader` to close+reopen the project's
  Mnemosyne repo so the new config takes effect.
  """

  use GingkoWeb, :live_component

  require Logger

  alias Gingko.Projects
  alias Gingko.Projects.ExtractionOverlay
  alias Phoenix.Component

  @step_help %{
    get_subgoal: "Extracting subgoals from agent episodes.",
    get_state: "Summarizing agent state for each trajectory step.",
    get_reward: "Scoring reward/return for a trajectory.",
    merge_intent: "Deciding when incoming intents should merge with existing ones.",
    reason_episodic: "Reasoning over episodic memories during recall.",
    reason_semantic: "Reasoning over semantic facts during recall.",
    reason_procedural: "Reasoning over procedural instructions during recall.",
    get_refined_query: "Refining the query between retrieval hops.",
    get_semantic: "Extracting semantic facts from trajectories.",
    get_procedural: "Extracting procedural instructions from trajectories.",
    get_return: "Computing the aggregate return across a trajectory.",
    get_mode: "Classifying recall mode (episodic/semantic/procedural).",
    get_plan: "Planning a retrieval strategy for the current query."
  }

  @impl true
  def update(assigns, socket) do
    overlay = assigns[:overlay] || Projects.get_extraction_overlay(assigns.project_id)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:overlay, overlay)
     |> assign(:form, build_form(overlay))
     |> assign(:step_keys, ExtractionOverlay.step_keys())
     |> assign(:base_options, base_option_tuples())
     |> assign(:step_help, @step_help)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <.panel title="Base profile" subtitle="Choose what this project builds its overlays on top of.">
        <.form
          for={@form}
          id={"overlays-form-#{@project_id}"}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
        >
          <div class="grid gap-2 sm:grid-cols-2">
            <label :for={{label, value} <- @base_options} class="flex items-center gap-2 text-sm">
              <input
                type="radio"
                name={@form[:base].name}
                value={value}
                checked={to_string(@form[:base].value) == value}
                class="radio radio-sm"
              />
              <span>{label}</span>
            </label>
          </div>

          <.input
            type="textarea"
            label="Domain context (optional)"
            field={@form[:domain_context]}
            rows="3"
            placeholder="Short description of this project's domain, injected into extraction prompts."
          />

          <div class="mt-4 space-y-3">
            <h3 class="text-sm font-semibold">Step overlays</h3>
            <p class="text-xs text-base-content/70">
              Leave blank to fall through to the base profile. Each overlay is capped at {ExtractionOverlay.max_overlay_length()} characters.
            </p>

            <details :for={step <- @step_keys} class="rounded border border-base-300 p-3">
              <summary class="cursor-pointer text-sm font-mono">{step}</summary>
              <p class="mt-1 text-xs text-base-content/70">{Map.get(@step_help, step, "")}</p>
              <textarea
                name={"extraction_overlay[steps][#{step}]"}
                rows="4"
                class="textarea textarea-bordered mt-2 w-full font-mono text-xs"
                placeholder="Additional instruction text for this pipeline step."
              >{step_value(@form, step)}</textarea>
            </details>
          </div>

          <div class="mt-4 flex items-center gap-3">
            <.button type="submit" class="btn btn-primary btn-sm">Save</.button>
            <.button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="reset"
              phx-target={@myself}
              data-confirm="Clear overlay and inherit the global profile?"
            >
              Reset to global
            </.button>
            <span :if={not ExtractionOverlay.empty?(@overlay)} class="text-xs text-base-content/60">
              Saving closes active sessions so the new overlay takes effect.
            </span>
          </div>
        </.form>
      </.panel>
    </section>
    """
  end

  @impl true
  def handle_event("validate", params, socket) do
    attrs = overlay_params(params)
    {:noreply, assign(socket, :form, Component.to_form(attrs, as: :extraction_overlay))}
  end

  def handle_event("save", params, socket) do
    project_id = socket.assigns.project_id

    case Projects.update_extraction_overlay(project_id, overlay_params(params)) do
      {:ok, project} ->
        overlay = ExtractionOverlay.from_project(project)
        forward_flash(:info, "Overlays saved; repo reloading.")

        {:noreply,
         socket
         |> assign(:overlay, overlay)
         |> assign(:form, build_form(overlay))}

      {:error, %Ecto.Changeset{} = changeset} ->
        forward_flash(:error, "Could not save overlays — check the fields.")

        attrs = Map.merge(overlay_params(params), %{"errors" => summarize_errors(changeset)})
        {:noreply, assign(socket, :form, Component.to_form(attrs, as: :extraction_overlay))}
    end
  end

  def handle_event("reset", _params, socket) do
    case Projects.reset_extraction_overlay(socket.assigns.project_id) do
      {:ok, project} ->
        overlay = ExtractionOverlay.from_project(project)
        forward_flash(:info, "Overlays reset to global; repo reloading.")

        {:noreply,
         socket
         |> assign(:overlay, overlay)
         |> assign(:form, build_form(overlay))}

      {:error, %Ecto.Changeset{}} ->
        forward_flash(:error, "Could not reset overlays.")
        {:noreply, socket}
    end
  end

  defp build_form(%ExtractionOverlay{} = overlay) do
    attrs = %{
      "base" => overlay.base,
      "domain_context" => overlay.domain_context || "",
      "steps" => stringify_steps(overlay.steps)
    }

    Component.to_form(attrs, as: :extraction_overlay)
  end

  defp stringify_steps(steps) when is_map(steps) do
    Map.new(steps, fn {k, v} -> {to_string(k), v} end)
  end

  defp overlay_params(params) do
    raw = Map.get(params, "extraction_overlay", %{})
    Map.take(raw, ["base", "domain_context", "steps"])
  end

  defp step_value(form, step) do
    case form[:steps].value do
      %{} = steps ->
        Map.get(steps, step) || Map.get(steps, to_string(step)) || ""

      _ ->
        ""
    end
  end

  defp summarize_errors(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, "; ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp base_option_tuples do
    [
      {"Inherit global", "inherit_global"},
      {"None", "none"},
      {"Coding", "coding"},
      {"Research", "research"},
      {"Customer support", "customer_support"}
    ]
  end

  defp forward_flash(kind, message) do
    send(self(), {:put_flash, kind, message})
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-base-300 bg-base-100 p-5">
      <header class="mb-3">
        <h2 class="text-lg font-semibold">{@title}</h2>
        <p :if={@subtitle} class="text-sm text-base-content/70">{@subtitle}</p>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end
end
