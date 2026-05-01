defmodule Gingko.Memory.GraphViewTest do
  use ExUnit.Case, async: true

  alias Gingko.Memory.GraphView
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node.Episodic
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.Graph.Node.Tag

  test "project_view builds serialized nodes, unique edges, and stats" do
    graph =
      Graph.new()
      |> Graph.put_node(%Semantic{
        id: "sem-1",
        proposition: "Elixir is functional",
        confidence: 0.9
      })
      |> Graph.put_node(%Tag{id: "tag-1", label: "elixir"})
      |> Graph.put_node(%Intent{id: "intent-1", description: "Learn OTP"})
      |> Graph.link("sem-1", "tag-1", :membership)
      |> Graph.link("sem-1", "intent-1", :provenance)

    view = GraphView.project_view(graph)

    assert view.mode == :project
    assert view.layout_mode == :force
    assert view.stats.node_count == 3
    assert view.stats.edge_count == 2
    assert view.stats.type_counts == %{intent: 1, semantic: 1, tag: 1}

    assert Enum.any?(view.nodes, &(&1.id == "sem-1" and &1.label == "Elixir is functional"))
    assert Enum.any?(view.nodes, &(&1.id == "tag-1" and &1.label == "elixir"))
    assert Enum.any?(view.nodes, &(&1.id == "intent-1" and &1.label == "Learn OTP"))

    semantic_node = Enum.find(view.nodes, &(&1.id == "sem-1"))
    assert semantic_node.type == :semantic
    assert "type-semantic" in semantic_node.classes
    assert semantic_node.layer_priority == 2
    assert is_binary(semantic_node.sort_key)

    tag_node = Enum.find(view.nodes, &(&1.id == "tag-1"))
    assert tag_node.layer_priority == 4

    intent_node = Enum.find(view.nodes, &(&1.id == "intent-1"))
    assert intent_node.layer_priority == 0

    assert Enum.sort(view.edges) == [
             %{id: "intent-1:sem-1", source: "intent-1", target: "sem-1", type: :provenance},
             %{id: "sem-1:tag-1", source: "sem-1", target: "tag-1", type: :membership}
           ]
  end

  test "focused_view centers on a node and expands neighbors adaptively" do
    graph =
      Graph.new()
      |> Graph.put_node(%Semantic{id: "sem-1", proposition: "Base fact", confidence: 0.9})
      |> Graph.put_node(%Tag{id: "tag-1", label: "tag one"})
      |> Graph.put_node(%Procedural{
        id: "proc-1",
        instruction: "Use Task.Supervisor",
        condition: "When tasks run in production",
        expected_outcome: "Supervised async execution"
      })
      |> Graph.put_node(%Source{id: "src-1", episode_id: "ep-1", step_index: 1})
      |> Graph.link("sem-1", "tag-1", :membership)
      |> Graph.link("tag-1", "proc-1", :sibling)
      |> Graph.link("proc-1", "src-1", :provenance)

    default_view = GraphView.focused_view(graph, "tag-1")

    assert default_view.mode == :focused
    assert default_view.layout_mode == :force
    assert default_view.selection.node_id == "tag-1"
    assert Enum.map(default_view.nodes, & &1.id) |> Enum.sort() == ["proc-1", "sem-1", "tag-1"]
    assert Enum.map(default_view.expandable_nodes, & &1.id) |> Enum.sort() == ["proc-1"]

    selected_node = Enum.find(default_view.nodes, &(&1.id == "tag-1"))
    assert selected_node.type == :tag
    assert "is-selected" in selected_node.classes
    assert "type-tag" in selected_node.classes

    expanded_view = GraphView.focused_view(graph, "tag-1", MapSet.new(["proc-1"]))

    assert Enum.map(expanded_view.nodes, & &1.id) |> Enum.sort() == [
             "proc-1",
             "sem-1",
             "src-1",
             "tag-1"
           ]

    assert Enum.any?(expanded_view.edges, &(&1.source == "proc-1" and &1.target == "src-1"))
  end

  test "session_view uses touched node ids as the base slice" do
    graph =
      Graph.new()
      |> Graph.put_node(%Semantic{id: "sem-1", proposition: "Base fact", confidence: 0.9})
      |> Graph.put_node(%Tag{id: "tag-1", label: "tag one"})
      |> Graph.put_node(%Intent{id: "intent-1", description: "Remember this"})
      |> Graph.link("sem-1", "tag-1", :membership)
      |> Graph.link("sem-1", "intent-1", :provenance)

    view = GraphView.session_view(graph, "session-1", ["sem-1"])

    assert view.mode == :session
    assert view.layout_mode == :force
    assert view.selection.session_id == "session-1"
    assert Enum.map(view.nodes, & &1.id) |> Enum.sort() == ["sem-1"]

    expanded = GraphView.session_view(graph, "session-1", ["sem-1"], MapSet.new(["sem-1"]))

    assert Enum.map(expanded.nodes, & &1.id) |> Enum.sort() == ["intent-1", "sem-1", "tag-1"]
    assert length(expanded.edges) == 2
  end

  test "query_view filters to touched nodes present in graph" do
    graph =
      Graph.new()
      |> Graph.put_node(%Semantic{id: "sem-1", proposition: "Known fact", confidence: 0.9})
      |> Graph.put_node(%Tag{id: "tag-1", label: "tag one"})
      |> Graph.put_node(%Intent{id: "intent-1", description: "Remember this"})
      |> Graph.link("sem-1", "tag-1", :membership)
      |> Graph.link("sem-1", "intent-1", :provenance)

    view = GraphView.query_view(graph, ["sem-1", "missing-node"])

    assert view.mode == :query
    assert view.title == "Query Graph"
    assert view.layout_mode == :force
    assert Enum.map(view.nodes, & &1.id) |> Enum.sort() == ["sem-1"]
    assert view.stats.node_count == 1
  end

  test "query_view expands neighbors of expanded nodes" do
    graph =
      Graph.new()
      |> Graph.put_node(%Semantic{id: "sem-1", proposition: "Base fact", confidence: 0.9})
      |> Graph.put_node(%Tag{id: "tag-1", label: "tag one"})
      |> Graph.put_node(%Intent{id: "intent-1", description: "Remember this"})
      |> Graph.link("sem-1", "tag-1", :membership)
      |> Graph.link("sem-1", "intent-1", :provenance)

    expanded = GraphView.query_view(graph, ["sem-1"], MapSet.new(["sem-1"]))

    assert Enum.map(expanded.nodes, & &1.id) |> Enum.sort() == ["intent-1", "sem-1", "tag-1"]
    assert length(expanded.edges) == 2
  end

  test "project_view derives graph-friendly labels for episodic and source nodes" do
    graph =
      Graph.new()
      |> Graph.put_node(%Episodic{
        id: "epi-1",
        observation: "User asked for a graph legend and better node labels",
        action: "Patched the Cytoscape viewport to show a cleaner tooltip",
        state: "completed",
        reward: 0.8,
        trajectory_id: "traj-1",
        subgoal: nil
      })
      |> Graph.put_node(%Source{id: "src-1", episode_id: "episode-123456789", step_index: 7})

    view = GraphView.project_view(graph)

    assert Enum.any?(view.nodes, fn node ->
             node.id == "epi-1" and
               node.label == "User asked for a graph..." and
               node.graph_label == "User asked for a graph..." and
               node.tooltip_sections == [
                 %{
                   label: "Observation",
                   value: "User asked for a graph legend and better node labels"
                 },
                 %{
                   label: "Action",
                   value: "Patched the Cytoscape viewport to show a cleaner tooltip"
                 },
                 %{label: "Reward", value: "0.8"}
               ] and
               node.tooltip_label ==
                 "Observation: User asked for a graph legend and better node labels\nAction: Patched the Cytoscape viewport to show a cleaner tooltip\nReward: 0.8"
           end)

    assert Enum.any?(view.nodes, fn node ->
             node.id == "src-1" and
               node.label == "Source step 7" and
               node.graph_label == "Source step 7" and
               node.tooltip_label == "Episode episode-123456789, step 7"
           end)
  end
end
