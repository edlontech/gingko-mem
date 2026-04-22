defmodule Gingko.Projects.ExtractionOverlayTest do
  use ExUnit.Case, async: true

  alias Gingko.Projects.ExtractionOverlay
  alias Gingko.Projects.Project
  alias Mnemosyne.ExtractionProfile

  describe "changeset/2" do
    test "drops unknown step keys and trims blanks" do
      attrs = %{
        "base" => "coding",
        "domain_context" => "  a project  ",
        "steps" => %{
          "get_semantic" => " hello ",
          "bogus_step" => "ignored",
          "get_reward" => ""
        }
      }

      cs = ExtractionOverlay.changeset(%ExtractionOverlay{}, attrs)
      assert cs.valid?
      overlay = Ecto.Changeset.apply_changes(cs)

      assert overlay.base == "coding"
      assert overlay.domain_context == "a project"
      assert overlay.steps == %{get_semantic: "hello"}
    end

    test "rejects unknown base" do
      cs = ExtractionOverlay.changeset(%ExtractionOverlay{}, %{"base" => "wat"})
      refute cs.valid?
      assert %{base: [_ | _]} = errors_on(cs)
    end

    test "rejects overlay text longer than the cap" do
      too_long = String.duplicate("x", ExtractionOverlay.max_overlay_length() + 1)
      attrs = %{"base" => "none", "steps" => %{"get_semantic" => too_long}}
      cs = ExtractionOverlay.changeset(%ExtractionOverlay{}, attrs)

      refute cs.valid?
      assert %{steps: [msg]} = errors_on(cs)
      assert msg =~ "exceeds"
    end
  end

  describe "from_project/1 and to_project_attrs/1" do
    test "round-trip preserves overlay data" do
      overlay = %ExtractionOverlay{
        base: "coding",
        domain_context: "ctx",
        steps: %{get_semantic: "hi", get_reward: "rw"}
      }

      attrs = ExtractionOverlay.to_project_attrs(overlay)
      assert attrs.overlay_base == "coding"
      assert attrs.overlay_domain_context == "ctx"
      assert attrs.overlay_steps == %{"get_semantic" => "hi", "get_reward" => "rw"}

      project = %Project{
        overlay_base: attrs.overlay_base,
        overlay_domain_context: attrs.overlay_domain_context,
        overlay_steps: attrs.overlay_steps,
        overlay_value_function_overrides: attrs.overlay_value_function_overrides
      }

      hydrated = ExtractionOverlay.from_project(project)
      assert hydrated.base == "coding"
      assert hydrated.domain_context == "ctx"
      assert hydrated.steps == %{get_semantic: "hi", get_reward: "rw"}
    end

    test "from_project ignores unknown string keys from storage" do
      project = %Project{
        overlay_base: "none",
        overlay_steps: %{"bogus_step" => "ignored", "get_semantic" => "hi"}
      }

      overlay = ExtractionOverlay.from_project(project)
      assert overlay.steps == %{get_semantic: "hi"}
    end
  end

  describe "empty?/1" do
    test "true for fresh default" do
      assert ExtractionOverlay.empty?(%ExtractionOverlay{})
    end

    test "false when base differs" do
      refute ExtractionOverlay.empty?(%ExtractionOverlay{base: "coding"})
    end

    test "false when domain_context present" do
      refute ExtractionOverlay.empty?(%ExtractionOverlay{domain_context: "x"})
    end

    test "false when any step set" do
      refute ExtractionOverlay.empty?(%ExtractionOverlay{steps: %{get_semantic: "x"}})
    end
  end

  describe "to_extraction_profile/2" do
    test "inherit_global returns the given global profile when overlay is empty" do
      global = ExtractionProfile.coding()
      assert ExtractionProfile.coding() == global

      overlay = %ExtractionOverlay{base: "inherit_global"}
      assert ExtractionOverlay.to_extraction_profile(overlay, global) == global
    end

    test "inherit_global with custom step merges on top of global" do
      global = ExtractionProfile.coding()
      overlay = %ExtractionOverlay{base: "inherit_global", steps: %{get_semantic: "custom"}}

      result = ExtractionOverlay.to_extraction_profile(overlay, global)
      assert result.overlays[:get_semantic] == "custom"
      assert result.overlays[:get_procedural] == global.overlays[:get_procedural]
    end

    test "none base with no overlays returns nil" do
      overlay = %ExtractionOverlay{base: "none"}
      assert ExtractionOverlay.to_extraction_profile(overlay, nil) == nil
    end

    test "none base with project overlays yields a custom profile" do
      overlay = %ExtractionOverlay{
        base: "none",
        domain_context: "ctx",
        steps: %{get_semantic: "hi"}
      }

      assert %ExtractionProfile{
               name: :custom,
               domain_context: "ctx",
               overlays: %{get_semantic: "hi"}
             } = ExtractionOverlay.to_extraction_profile(overlay, nil)
    end

    test "coding base replaces any inherit_global" do
      global = ExtractionProfile.research()
      overlay = %ExtractionOverlay{base: "coding"}
      result = ExtractionOverlay.to_extraction_profile(overlay, global)

      assert result.name == :coding
      assert result.overlays == ExtractionProfile.coding().overlays
    end

    test "project domain_context overrides base when non-blank" do
      overlay = %ExtractionOverlay{base: "coding", domain_context: "special"}
      result = ExtractionOverlay.to_extraction_profile(overlay, nil)
      assert result.domain_context == "special"
    end
  end

  describe "step_keys/0 drift guard" do
    test "covers every Config.resolve_overlay call site in Mnemosyne" do
      pipeline_dir =
        Application.app_dir(:mnemosyne, "")
        |> Path.dirname()
        |> Path.join("mnemosyne/lib/mnemosyne/pipeline")

      pipeline_dir =
        if File.dir?(pipeline_dir),
          do: pipeline_dir,
          else: Path.expand("../../../deps/mnemosyne/lib/mnemosyne/pipeline", __DIR__)

      atoms =
        pipeline_dir
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          source = File.read!(path)

          Regex.scan(~r/Config\.resolve_overlay\(.*?,\s*:([a-z_]+)\)/s, source,
            capture: :all_but_first
          )
        end)
        |> List.flatten()
        |> Enum.map(&String.to_atom/1)
        |> Enum.uniq()
        |> Enum.sort()

      missing = atoms -- ExtractionOverlay.step_keys()
      extra = ExtractionOverlay.step_keys() -- atoms

      assert missing == [], "Mnemosyne added new overlay steps: #{inspect(missing)}"

      assert extra == [],
             "ExtractionOverlay lists steps Mnemosyne does not use: #{inspect(extra)}"
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
