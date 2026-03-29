defmodule Gingko.Memory.GraphClusterTest do
  use ExUnit.Case, async: true

  alias Gingko.Memory.GraphCluster
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node.Intent
  alias Mnemosyne.Graph.Node.Procedural
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Source
  alias Mnemosyne.Graph.Node.Tag

  describe "cluster/1 threshold behavior" do
    test "returns :flat for graphs under threshold" do
      graph =
        Enum.reduce(1..99, Graph.new(), fn i, g ->
          Graph.put_node(g, %Semantic{
            id: "sem-#{i}",
            proposition: "Fact #{i}",
            confidence: 0.9
          })
        end)

      assert :flat = GraphCluster.cluster(graph)
    end

    test "returns :flat at exactly the threshold (100 nodes)" do
      graph =
        Enum.reduce(1..100, Graph.new(), fn i, g ->
          Graph.put_node(g, %Semantic{
            id: "sem-#{i}",
            proposition: "Fact #{i}",
            confidence: 0.9
          })
        end)

      assert :flat = GraphCluster.cluster(graph)
    end

    test "returns {:clustered, clusters} above threshold" do
      graph =
        Enum.reduce(1..101, Graph.new(), fn i, g ->
          Graph.put_node(g, %Semantic{
            id: "sem-#{i}",
            proposition: "Fact #{i}",
            confidence: 0.9
          })
        end)

      assert {:clustered, clusters} = GraphCluster.cluster(graph)
      assert is_list(clusters)
      assert length(clusters) > 0
    end
  end

  describe "compute_clusters/1" do
    test "returns empty list for empty graph" do
      assert [] = GraphCluster.compute_clusters(Graph.new())
    end

    test "disconnected graph produces separate components" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "a1", proposition: "Cluster A node 1", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "a2", proposition: "Cluster A node 2", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "a3", proposition: "Cluster A node 3", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "b1", label: "Cluster B node 1"})
        |> Graph.put_node(%Tag{id: "b2", label: "Cluster B node 2"})
        |> Graph.put_node(%Tag{id: "b3", label: "Cluster B node 3"})
        |> Graph.link("a1", "a2", :sibling)
        |> Graph.link("a2", "a3", :sibling)
        |> Graph.link("b1", "b2", :membership)
        |> Graph.link("b2", "b3", :membership)

      clusters = GraphCluster.compute_clusters(graph)

      assert length(clusters) == 2

      all_node_ids =
        clusters
        |> Enum.flat_map(&MapSet.to_list(&1.node_ids))
        |> Enum.sort()

      assert all_node_ids == ["a1", "a2", "a3", "b1", "b2", "b3"]

      cluster_a = Enum.find(clusters, &MapSet.member?(&1.node_ids, "a1"))
      cluster_b = Enum.find(clusters, &MapSet.member?(&1.node_ids, "b1"))

      assert MapSet.equal?(cluster_a.node_ids, MapSet.new(["a1", "a2", "a3"]))
      assert MapSet.equal?(cluster_b.node_ids, MapSet.new(["b1", "b2", "b3"]))
    end

    test "single connected component stays as one cluster" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "s1", proposition: "Fact 1", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "s2", proposition: "Fact 2", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "t1", label: "tag"})
        |> Graph.link("s1", "s2", :sibling)
        |> Graph.link("s2", "t1", :membership)

      clusters = GraphCluster.compute_clusters(graph)

      assert length(clusters) == 1
      assert MapSet.equal?(hd(clusters).node_ids, MapSet.new(["s1", "s2", "t1"]))
    end

    test "small components are merged into most-connected regular cluster" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "big-1", proposition: "Big 1", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "big-2", proposition: "Big 2", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "big-3", proposition: "Big 3", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "big-4", proposition: "Big 4", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "small-1", label: "Orphan"})
        |> Graph.link("big-1", "big-2", :sibling)
        |> Graph.link("big-2", "big-3", :sibling)
        |> Graph.link("big-3", "big-4", :sibling)
        |> Graph.link("small-1", "big-1", :membership)

      clusters = GraphCluster.compute_clusters(graph)

      assert length(clusters) == 1
      assert MapSet.member?(hd(clusters).node_ids, "small-1")
    end

    test "small components with no regular clusters are combined" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "a", proposition: "A", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "b", label: "B"})

      clusters = GraphCluster.compute_clusters(graph)

      assert length(clusters) == 1
      assert MapSet.equal?(hd(clusters).node_ids, MapSet.new(["a", "b"]))
    end

    test "large dense component is subdivided by label propagation" do
      node_count = 80
      nodes = for i <- 1..node_count, do: "n-#{String.pad_leading("#{i}", 3, "0")}"

      graph =
        Enum.reduce(nodes, Graph.new(), fn id, g ->
          Graph.put_node(g, %Semantic{id: id, proposition: "Node #{id}", confidence: 0.5})
        end)

      half = div(node_count, 2)
      first_half = Enum.take(nodes, half)
      second_half = Enum.drop(nodes, half)

      link_clique = fn group, g ->
        group
        |> Enum.chunk_every(5)
        |> Enum.reduce(g, fn chunk, acc ->
          for a <- chunk, b <- chunk, a < b, reduce: acc do
            acc -> Graph.link(acc, a, b, :sibling)
          end
        end)
      end

      graph = link_clique.(first_half, graph)
      graph = link_clique.(second_half, graph)

      bridge_a = List.last(first_half)
      bridge_b = hd(second_half)
      graph = Graph.link(graph, bridge_a, bridge_b, :sibling)

      clusters = GraphCluster.compute_clusters(graph)

      assert length(clusters) >= 2

      total_nodes =
        clusters
        |> Enum.flat_map(&MapSet.to_list(&1.node_ids))
        |> Enum.uniq()
        |> length()

      assert total_nodes == node_count
    end
  end

  describe "determinism" do
    test "same graph always produces the same cluster IDs" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "s1", proposition: "One", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "s2", proposition: "Two", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "t1", label: "tag"})
        |> Graph.link("s1", "s2", :sibling)
        |> Graph.link("s2", "t1", :membership)

      clusters_a = GraphCluster.compute_clusters(graph)
      clusters_b = GraphCluster.compute_clusters(graph)

      ids_a = Enum.map(clusters_a, & &1.id) |> Enum.sort()
      ids_b = Enum.map(clusters_b, & &1.id) |> Enum.sort()

      assert ids_a == ids_b
    end
  end

  describe "type_distribution" do
    test "correctly counts node types within a cluster" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "s1", proposition: "Fact", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "s2", proposition: "Fact 2", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "t1", label: "tag"})
        |> Graph.put_node(%Intent{id: "i1", description: "Goal"})
        |> Graph.link("s1", "s2", :sibling)
        |> Graph.link("s2", "t1", :membership)
        |> Graph.link("t1", "i1", :provenance)

      [cluster] = GraphCluster.compute_clusters(graph)

      assert cluster.type_distribution == %{semantic: 2, tag: 1, intent: 1}
    end
  end

  describe "representative_label" do
    test "selects label of highest-degree node" do
      graph =
        Graph.new()
        |> Graph.put_node(%Tag{id: "hub", label: "Central Hub"})
        |> Graph.put_node(%Semantic{id: "s1", proposition: "Spoke 1", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "s2", proposition: "Spoke 2", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "s3", proposition: "Spoke 3", confidence: 0.9})
        |> Graph.link("hub", "s1", :membership)
        |> Graph.link("hub", "s2", :membership)
        |> Graph.link("hub", "s3", :membership)

      [cluster] = GraphCluster.compute_clusters(graph)

      assert cluster.representative_label == "Central Hub"
    end

    test "extracts label from various node types" do
      graph =
        Graph.new()
        |> Graph.put_node(%Procedural{
          id: "p1",
          instruction: "Do the thing",
          condition: "When ready",
          expected_outcome: "Done"
        })
        |> Graph.put_node(%Semantic{id: "s1", proposition: "Leaf", confidence: 0.5})
        |> Graph.put_node(%Semantic{id: "s2", proposition: "Leaf 2", confidence: 0.5})
        |> Graph.link("p1", "s1", :provenance)
        |> Graph.link("p1", "s2", :provenance)

      [cluster] = GraphCluster.compute_clusters(graph)

      assert cluster.representative_label == "Do the thing"
    end

    test "falls back to id when no text fields are present" do
      graph =
        Graph.new()
        |> Graph.put_node(%Source{id: "src-1", episode_id: "ep-1", step_index: 1})
        |> Graph.put_node(%Source{id: "src-2", episode_id: "ep-1", step_index: 2})
        |> Graph.put_node(%Source{id: "src-3", episode_id: "ep-1", step_index: 3})
        |> Graph.link("src-1", "src-2", :provenance)
        |> Graph.link("src-2", "src-3", :provenance)

      [cluster] = GraphCluster.compute_clusters(graph)

      assert is_binary(cluster.representative_label)
    end
  end

  describe "internal_edge_count" do
    test "counts edges inside a cluster" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "s1", proposition: "A", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "s2", proposition: "B", confidence: 0.9})
        |> Graph.put_node(%Semantic{id: "s3", proposition: "C", confidence: 0.9})
        |> Graph.link("s1", "s2", :sibling)
        |> Graph.link("s2", "s3", :sibling)
        |> Graph.link("s1", "s3", :sibling)

      [cluster] = GraphCluster.compute_clusters(graph)

      assert cluster.internal_edge_count == 3
    end
  end

  describe "cluster_id/1" do
    test "produces deterministic hash-based IDs" do
      ids = MapSet.new(["a", "b", "c"])
      assert "cluster:" <> hash = GraphCluster.cluster_id(ids)
      assert byte_size(hash) == 12
      assert GraphCluster.cluster_id(ids) == GraphCluster.cluster_id(ids)
    end

    test "order-independent: same set gives same ID" do
      id1 = GraphCluster.cluster_id(MapSet.new(["z", "a", "m"]))
      id2 = GraphCluster.cluster_id(MapSet.new(["a", "m", "z"]))
      assert id1 == id2
    end
  end

  describe "ETS cache" do
    test "get_cached returns :miss when nothing is cached" do
      assert :miss = GraphCluster.get_cached("project-cache-miss-#{System.unique_integer()}")
    end

    test "put_cached and get_cached round-trip" do
      project_id = "project-roundtrip-#{System.unique_integer()}"
      clusters = [%{id: "cluster:abc", node_ids: MapSet.new(["a"])}]

      assert :ok = GraphCluster.put_cached(project_id, clusters)
      assert {:ok, {0, ^clusters}} = GraphCluster.get_cached(project_id)
    end

    test "bump_version invalidates stale cache" do
      project_id = "project-bump-#{System.unique_integer()}"
      clusters = [%{id: "cluster:abc", node_ids: MapSet.new(["a"])}]

      GraphCluster.put_cached(project_id, clusters)
      assert {:ok, {0, _}} = GraphCluster.get_cached(project_id)

      new_version = GraphCluster.bump_version(project_id)
      assert new_version == 1
      assert :miss = GraphCluster.get_cached(project_id)
    end

    test "bump_version increments monotonically" do
      project_id = "project-mono-#{System.unique_integer()}"

      assert 1 = GraphCluster.bump_version(project_id)
      assert 2 = GraphCluster.bump_version(project_id)
      assert 3 = GraphCluster.bump_version(project_id)
    end
  end

  describe "cluster output shape" do
    test "cluster map contains all required fields" do
      graph =
        Graph.new()
        |> Graph.put_node(%Semantic{id: "s1", proposition: "Fact", confidence: 0.9})
        |> Graph.put_node(%Tag{id: "t1", label: "tag"})
        |> Graph.put_node(%Tag{id: "t2", label: "tag2"})
        |> Graph.link("s1", "t1", :membership)
        |> Graph.link("s1", "t2", :membership)

      [cluster] = GraphCluster.compute_clusters(graph)

      assert "cluster:" <> _ = cluster.id
      assert %MapSet{} = cluster.node_ids
      assert is_integer(cluster.node_count)
      assert cluster.node_count == 3
      assert is_map(cluster.type_distribution)
      assert is_binary(cluster.representative_label)
      assert is_integer(cluster.internal_edge_count)
    end
  end
end
