defmodule Gingko.Summaries.PrimerRendererTest do
  use ExUnit.Case, async: true

  alias Gingko.Summaries.ClusterSummary
  alias Gingko.Summaries.PrimerRenderer

  @playbook "# Playbook\n\nBody."

  test "omits charter region entirely when charter is nil" do
    out = PrimerRenderer.render(@playbook, nil, nil, [], [])
    refute out =~ "region:charter"
  end

  test "omits charter region entirely when charter is empty" do
    out = PrimerRenderer.render(@playbook, "", nil, [], [])
    refute out =~ "region:charter"
  end

  test "renders placeholder when state section is absent" do
    out = PrimerRenderer.render(@playbook, nil, nil, [], [])
    assert out =~ "region:state"
    assert out =~ "_Not yet generated._"
  end

  test "renders placeholder when state section has empty content" do
    out =
      PrimerRenderer.render(
        @playbook,
        nil,
        %{content: "", updated_at: ~U[2026-04-21 00:00:00Z]},
        [],
        []
      )

    assert out =~ "_Not yet generated._"
  end

  test "renders cluster index placeholder when no clusters exist" do
    out = PrimerRenderer.render(@playbook, nil, nil, [], [])
    assert out =~ "region:cluster_index"
    assert out =~ "_No clusters yet._"
  end

  test "renders recent memories placeholder when list is empty" do
    out = PrimerRenderer.render(@playbook, nil, nil, [], [])
    assert out =~ "region:recent_memories"
    assert out =~ "_No recent memories._"
  end

  test "renders cluster index with locked rows filtered" do
    clusters = [
      cluster(slug: "auth", memory_count: 10, headline: "auth stuff", locked: false),
      cluster(slug: "private", memory_count: 5, headline: "hidden", locked: true)
    ]

    out = PrimerRenderer.render(@playbook, nil, nil, clusters, [])

    assert out =~ "**auth**"
    assert out =~ "— auth stuff"
    refute out =~ "**private**"
  end

  test "charter region present when content is provided" do
    out = PrimerRenderer.render(@playbook, "some charter", nil, [], [])
    assert out =~ "region:charter"
    assert out =~ "# Project Charter"
    assert out =~ "some charter"
  end

  test "state region shows updated_at in heading when content present" do
    section = %{content: "state body", updated_at: ~U[2026-04-21 12:00:00Z]}
    out = PrimerRenderer.render(@playbook, nil, section, [], [])
    assert out =~ "# Project State — updated 2026-04-21T12:00:00Z"
    assert out =~ "state body"
  end

  test "all five region comments present in the happy path" do
    out =
      PrimerRenderer.render(
        @playbook,
        "charter body",
        %{content: "state body", updated_at: ~U[2026-04-21 12:00:00Z]},
        [cluster()],
        [memory()]
      )

    for region <- ~w(playbook charter state cluster_index recent_memories) do
      assert out =~ "<!-- region:#{region} -->", "missing opening comment for #{region}"
      assert out =~ "<!-- /region:#{region} -->", "missing closing comment for #{region}"
    end
  end

  test "playbook region wraps the supplied playbook body" do
    out = PrimerRenderer.render(@playbook, nil, nil, [], [])
    assert out =~ "<!-- region:playbook -->"
    assert out =~ @playbook
    assert out =~ "<!-- /region:playbook -->"
  end

  defp cluster(overrides \\ []) do
    base = %{
      slug: "s",
      memory_count: 1,
      headline: "h",
      locked: false,
      last_generated_at: ~U[2026-04-20 00:00:00Z]
    }

    struct(ClusterSummary, Map.merge(base, Map.new(overrides)))
  end

  defp memory do
    %{
      node: %{type: "semantic", proposition: "remembered thing"},
      metadata: %{created_at: ~U[2026-04-20 00:00:00Z]}
    }
  end
end
