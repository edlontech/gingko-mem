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

  describe "clustered_project_view/2" do
    test "delegates to flat project_view for small graphs" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "sem-1", proposition: "Fact one", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "tag-1", label: "elixir"})
        |> Graph.link("sem-1", "tag-1", :membership)

      view = GraphView.clustered_project_view(graph)

      assert view.mode == :project
      assert view.layout_mode == :force
      assert view.stats.node_count == 2
    end

    test "returns cluster meta-nodes for large graphs" do
      graph = build_large_graph(120)

      view = GraphView.clustered_project_view(graph)

      assert view.mode == :clustered_project
      assert view.title == "Project Graph (clustered)"
      assert view.layout_mode == :force
      assert view.selection == %{node_id: nil, session_id: nil}
      assert view.expandable_nodes == []
      assert length(view.nodes) >= 1
      assert view.stats.cluster_count >= 1
    end

    test "cluster meta-nodes have all required fields" do
      graph = build_large_graph(120)

      view = GraphView.clustered_project_view(graph)

      Enum.each(view.nodes, fn node ->
        assert is_binary(node.id)
        assert String.starts_with?(node.id, "cluster:")
        assert is_binary(node.label)
        assert is_binary(node.graph_label)
        assert is_binary(node.tooltip_label)
        assert is_list(node.tooltip_sections)
        assert length(node.tooltip_sections) == 3
        assert node.type == :cluster
        assert is_integer(node.node_count)
        assert is_map(node.type_distribution)
        assert is_integer(node.internal_edge_count)
        assert is_integer(node.degree)
        assert node.classes == ["type-cluster"]
        assert node.layer_priority == 0
        assert node.sort_key == nil
        assert node.details == %{}
      end)
    end

    test "inter-cluster edges have correct shape" do
      graph = build_two_cluster_graph()

      view = GraphView.clustered_project_view(graph)

      Enum.each(view.edges, fn edge ->
        assert is_binary(edge.id)
        assert String.starts_with?(edge.source, "cluster:")
        assert String.starts_with?(edge.target, "cluster:")
        assert edge.type == "inter_cluster"
        assert is_integer(edge.weight)
        assert edge.weight > 0
      end)
    end

    test "cluster degrees reflect inter-cluster edge counts" do
      graph = build_two_cluster_graph()

      view = GraphView.clustered_project_view(graph)

      nodes_with_edges =
        Enum.filter(view.nodes, &(&1.degree > 0))

      if length(view.edges) > 0 do
        assert length(nodes_with_edges) >= 1
      end
    end

    test "stats aggregate type counts across clusters" do
      graph = build_large_graph(120)

      view = GraphView.clustered_project_view(graph)

      assert view.stats.node_count == 120
      assert view.stats.edge_count == 119
      assert is_integer(view.stats.cluster_count)
      assert is_map(view.stats.type_counts)

      total_from_types = view.stats.type_counts |> Map.values() |> Enum.sum()
      assert total_from_types == 120
    end
  end

  describe "expand_cluster/3" do
    test "returns nodes and edges for a valid cluster" do
      graph = build_large_graph(120)
      {:clustered, clusters} = Gingko.Memory.GraphCluster.cluster(graph)

      cluster = hd(clusters)
      {:ok, result} = GraphView.expand_cluster(graph, cluster.id, clusters)

      assert result.cluster_id == cluster.id
      assert result.layout_mode == :force
      assert length(result.nodes) == cluster.node_count

      Enum.each(result.nodes, fn node ->
        assert is_binary(node.id)
        assert is_binary(node.label)
        assert is_atom(node.type)
        assert is_list(node.classes)
      end)
    end

    test "returns error for unknown cluster id" do
      graph = build_large_graph(120)
      {:clustered, clusters} = Gingko.Memory.GraphCluster.cluster(graph)

      assert {:error, :cluster_not_found} =
               GraphView.expand_cluster(graph, "cluster:nonexistent", clusters)
    end
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

  defp build_large_graph(count) do
    graph =
      Enum.reduce(1..count, Graph.new(), fn i, g ->
        node =
          if rem(i, 2) == 0 do
            %Semantic{id: "sem-#{i}", proposition: "Fact #{i}", confidence: 0.9}
          else
            %Episodic{
              id: "epi-#{i}",
              observation: "Observed #{i}",
              action: "Did #{i}",
              state: "done",
              subgoal: nil,
              reward: 0.5,
              trajectory_id: "traj-1"
            }
          end

        Graph.put_node(g, node)
      end)

    Enum.reduce(1..(count - 1), graph, fn i, g ->
      source = if rem(i, 2) == 0, do: "sem-#{i}", else: "epi-#{i}"
      target = if rem(i + 1, 2) == 0, do: "sem-#{i + 1}", else: "epi-#{i + 1}"
      Graph.link(g, source, target, :sibling)
    end)
  end

  defp build_two_cluster_graph do
    cluster_a =
      Enum.reduce(1..60, Graph.new(), fn i, g ->
        Graph.put_node(g, %Semantic{
          id: "a-sem-#{i}",
          proposition: "Cluster A fact #{i}",
          confidence: 0.9
        })
      end)

    cluster_a =
      Enum.reduce(1..59, cluster_a, fn i, g ->
        Graph.link(g, "a-sem-#{i}", "a-sem-#{i + 1}", :sibling)
      end)

    cluster_b =
      Enum.reduce(1..60, cluster_a, fn i, g ->
        Graph.put_node(g, %Episodic{
          id: "b-epi-#{i}",
          observation: "Cluster B obs #{i}",
          action: "Action #{i}",
          state: "done",
          subgoal: nil,
          reward: 0.5,
          trajectory_id: "traj-b"
        })
      end)

    cluster_b =
      Enum.reduce(1..59, cluster_b, fn i, g ->
        Graph.link(g, "b-epi-#{i}", "b-epi-#{i + 1}", :sibling)
      end)

    Graph.link(cluster_b, "a-sem-1", "b-epi-1", :provenance)
  end
end
