defmodule Gingko.Summaries.PrimerRendererTest do
  use ExUnit.Case, async: true

  alias Gingko.Summaries.PrimerRenderer

  test "omits charter region when charter is nil or empty" do
    assert refute_region(PrimerRenderer.render(nil, nil, []), :charter)
    assert refute_region(PrimerRenderer.render("", nil, []), :charter)
  end

  test "renders placeholder when summary section is absent" do
    out = PrimerRenderer.render(nil, nil, [])
    assert out =~ "<!-- region:summary -->"
    assert out =~ "_Not yet generated._"
  end

  test "renders placeholder when summary section has empty content" do
    out =
      PrimerRenderer.render(
        nil,
        %{content: "", updated_at: ~U[2026-04-21 00:00:00Z]},
        []
      )

    assert out =~ "_Not yet generated._"
  end

  test "renders recent memories placeholder when list is empty" do
    out = PrimerRenderer.render(nil, nil, [])
    assert out =~ "<!-- region:recent_memories -->"
    assert out =~ "_No recent memories._"
  end

  test "charter region present when content is provided" do
    out = PrimerRenderer.render("some charter", nil, [])
    assert out =~ "<!-- region:charter -->"
    assert out =~ "# Project Charter"
    assert out =~ "some charter"
  end

  test "summary region shows updated_at in heading when content present" do
    section = %{content: "constitution body", updated_at: ~U[2026-04-21 12:00:00Z]}
    out = PrimerRenderer.render(nil, section, [])
    assert out =~ "# Project Summary — updated 2026-04-21T12:00:00Z"
    assert out =~ "constitution body"
  end

  test "all four region comments present in the happy path" do
    out =
      PrimerRenderer.render(
        "charter body",
        %{content: "summary body", updated_at: ~U[2026-04-21 12:00:00Z]},
        [memory()]
      )

    for region <- ~w(playbook charter summary recent_memories) do
      assert out =~ "<!-- region:#{region} -->", "missing opening comment for #{region}"
      assert out =~ "<!-- /region:#{region} -->", "missing closing comment for #{region}"
    end
  end

  test "playbook region wraps the static playbook" do
    out = PrimerRenderer.render(nil, nil, [])
    assert out =~ "<!-- region:playbook -->"
    assert out =~ "Gingko Memory — Recall Playbook"
    assert out =~ "<!-- /region:playbook -->"
  end

  defp refute_region(rendered, kind) do
    not String.contains?(rendered, "region:#{kind}")
  end

  defp memory do
    %{
      node: %{type: "semantic", proposition: "remembered thing"},
      metadata: %{created_at: ~U[2026-04-20 00:00:00Z]}
    }
  end
end
