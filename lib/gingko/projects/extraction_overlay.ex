defmodule Gingko.Projects.ExtractionOverlay do
  @moduledoc """
  Per-project Mnemosyne extraction profile override.

  A project can select a base profile (inherit the global one, use a Mnemosyne
  built-in, or start from nothing), then layer its own `domain_context` and
  per-step overlay text on top. Overlays target specific LLM pipeline steps
  and are injected when Mnemosyne builds prompt messages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Gingko.Projects.Project
  alias Mnemosyne.ExtractionProfile

  @base_options ~w(inherit_global none coding research customer_support)
  @step_keys [
    :get_subgoal,
    :get_state,
    :get_reward,
    :merge_intent,
    :reason_episodic,
    :reason_semantic,
    :reason_procedural,
    :get_refined_query,
    :get_semantic,
    :get_procedural,
    :get_return,
    :get_mode,
    :get_plan
  ]
  @step_key_strings Enum.map(@step_keys, &Atom.to_string/1)
  @max_overlay_length 8_000

  @primary_key false
  embedded_schema do
    field(:base, :string, default: "inherit_global")
    field(:domain_context, :string)
    field(:steps, :map, default: %{})
    field(:value_function_overrides, :map, default: %{})
  end

  @type t :: %__MODULE__{
          base: String.t(),
          domain_context: String.t() | nil,
          steps: %{atom() => String.t()},
          value_function_overrides: %{atom() => map()}
        }

  def step_keys, do: @step_keys
  def base_options, do: @base_options
  def max_overlay_length, do: @max_overlay_length

  @doc """
  Builds a form-friendly changeset. Unknown step keys are dropped, blank
  overlays are removed, and each overlay value is capped at
  `max_overlay_length/0` characters.
  """
  def changeset(%__MODULE__{} = overlay, attrs) do
    overlay
    |> cast(attrs, [:base, :domain_context, :steps, :value_function_overrides])
    |> validate_inclusion(:base, @base_options)
    |> update_change(:domain_context, &normalize_blank/1)
    |> update_change(:steps, &clean_steps/1)
    |> validate_step_lengths()
  end

  @doc """
  Hydrates the overlay from a persisted Project row. Normalizes string keys
  read back from SQLite/JSON into the known atom set.
  """
  def from_project(%Project{} = project) do
    %__MODULE__{
      base: project.overlay_base || "inherit_global",
      domain_context: normalize_blank(project.overlay_domain_context),
      steps: normalize_step_map(project.overlay_steps || %{}),
      value_function_overrides: project.overlay_value_function_overrides || %{}
    }
  end

  @doc """
  Builds the attrs map to persist on a Project row.
  """
  def to_project_attrs(%__MODULE__{} = overlay) do
    %{
      overlay_base: overlay.base,
      overlay_domain_context: overlay.domain_context,
      overlay_steps: stringify_step_keys(overlay.steps),
      overlay_value_function_overrides: overlay.value_function_overrides || %{},
      overlay_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  def empty?(%__MODULE__{} = overlay) do
    overlay.base == "inherit_global" and
      map_size(overlay.steps) == 0 and
      overlay.domain_context in [nil, ""]
  end

  @doc """
  Resolves the effective `%Mnemosyne.ExtractionProfile{}` for this overlay,
  merging project values on top of the chosen base profile.

  Returns nil when the result would contribute no overlay data.
  """
  @spec to_extraction_profile(t(), ExtractionProfile.t() | nil) :: ExtractionProfile.t() | nil
  def to_extraction_profile(%__MODULE__{} = overlay, global_profile) do
    base = resolve_base_profile(overlay.base, global_profile)
    build_merged_profile(base, overlay)
  end

  defp resolve_base_profile("inherit_global", global), do: global
  defp resolve_base_profile("none", _global), do: nil
  defp resolve_base_profile("coding", _global), do: ExtractionProfile.coding()
  defp resolve_base_profile("research", _global), do: ExtractionProfile.research()

  defp resolve_base_profile("customer_support", _global),
    do: ExtractionProfile.customer_support()

  defp build_merged_profile(nil, %__MODULE__{} = overlay) do
    if map_size(overlay.steps) > 0 or is_binary(overlay.domain_context) do
      %ExtractionProfile{
        name: :custom,
        domain_context: overlay.domain_context || "",
        overlays: overlay.steps,
        value_function_overrides: overlay.value_function_overrides || %{}
      }
    end
  end

  defp build_merged_profile(%ExtractionProfile{} = base, %__MODULE__{} = overlay) do
    domain_context =
      case overlay.domain_context do
        value when is_binary(value) and value != "" -> value
        _ -> base.domain_context
      end

    %ExtractionProfile{
      base
      | domain_context: domain_context,
        overlays: Map.merge(base.overlays, overlay.steps),
        value_function_overrides:
          Map.merge(base.value_function_overrides, overlay.value_function_overrides || %{})
    }
  end

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_steps(nil), do: %{}

  defp clean_steps(map) when is_map(map) do
    normalize_step_map(map)
  end

  defp normalize_step_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case {normalize_step_key(key), normalize_blank(value)} do
        {nil, _} -> acc
        {_key, nil} -> acc
        {atom, text} -> Map.put(acc, atom, text)
      end
    end)
  end

  defp normalize_step_key(key) when is_atom(key) do
    if key in @step_keys, do: key, else: nil
  end

  defp normalize_step_key(key) when is_binary(key) do
    if key in @step_key_strings, do: String.to_existing_atom(key), else: nil
  end

  defp normalize_step_key(_), do: nil

  defp stringify_step_keys(steps) when is_map(steps) do
    Enum.reduce(steps, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp validate_step_lengths(changeset) do
    case get_change(changeset, :steps) do
      nil -> changeset
      steps when is_map(steps) -> add_overlay_length_error(changeset, steps)
    end
  end

  defp add_overlay_length_error(changeset, steps) do
    case Enum.find(steps, &overlay_too_long?/1) do
      nil ->
        changeset

      {key, _} ->
        add_error(
          changeset,
          :steps,
          "overlay for #{key} exceeds #{@max_overlay_length} characters"
        )
    end
  end

  defp overlay_too_long?({_key, value}) when is_binary(value),
    do: String.length(value) > @max_overlay_length

  defp overlay_too_long?(_), do: false
end
