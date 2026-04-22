defmodule Gingko.Memory.GraphView do
  @moduledoc false

  alias Gingko.Memory.GraphCluster
  alias Gingko.Memory.Serializer
  alias Mnemosyne.Graph

  @spec project_view(Graph.t(), keyword()) :: map()
  def project_view(%Graph{} = graph, opts \\ []) do
    build_view(:project, graph, visible_ids(graph), opts)
  end

  @spec clustered_project_view(Graph.t(), keyword()) :: map()
  def clustered_project_view(%Graph{} = graph, opts \\ []) do
    case GraphCluster.cluster(graph) do
      :flat ->
        project_view(graph, opts)

      {:clustered, clusters} ->
        build_clustered_view(graph, clusters, opts)
    end
  end

  @spec expand_cluster(Graph.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, :cluster_not_found}
  def expand_cluster(%Graph{} = graph, cluster_id, clusters) do
    case Enum.find(clusters, &(&1.id == cluster_id)) do
      nil ->
        {:error, :cluster_not_found}

      cluster ->
        visible_ids =
          cluster.node_ids
          |> MapSet.to_list()
          |> Enum.filter(&Map.has_key?(graph.nodes, &1))

        nodes =
          visible_ids
          |> Enum.map(&Map.fetch!(graph.nodes, &1))
          |> Enum.map(&serialize_node(&1, %{}))
          |> Enum.sort_by(& &1.id)

        visible_id_set = MapSet.new(visible_ids)
        edges = build_edges(graph, visible_id_set) |> Enum.sort_by(& &1.id)

        {:ok, %{cluster_id: cluster_id, nodes: nodes, edges: edges, layout_mode: :force}}
    end
  end

  @spec focused_view(Graph.t(), String.t() | nil, MapSet.t()) :: map()
  def focused_view(graph, node_id, expanded_node_ids \\ MapSet.new())

  def focused_view(%Graph{} = graph, nil, expanded_node_ids) do
    build_view(:focused, graph, [],
      selection: %{node_id: nil},
      expanded_node_ids: expanded_node_ids
    )
  end

  def focused_view(%Graph{} = graph, node_id, expanded_node_ids) when is_binary(node_id) do
    visible_ids =
      graph
      |> centered_visible_ids(node_id, expanded_node_ids)
      |> Enum.uniq()

    build_view(:focused, graph, visible_ids,
      selection: %{node_id: node_id},
      expanded_node_ids: expanded_node_ids
    )
  end

  @spec session_view(Graph.t(), String.t() | nil, [String.t()], MapSet.t()) :: map()
  def session_view(graph, session_id, node_ids, expanded_node_ids \\ MapSet.new())

  def session_view(%Graph{} = graph, session_id, node_ids, expanded_node_ids) do
    base_ids = Enum.filter(node_ids, &Map.has_key?(graph.nodes, &1))

    visible_ids =
      expanded_node_ids
      |> Enum.reduce(base_ids, fn node_id, acc ->
        acc ++ one_hop_ids(graph, node_id)
      end)
      |> Enum.uniq()

    build_view(:session, graph, visible_ids,
      selection: %{session_id: session_id},
      expanded_node_ids: expanded_node_ids
    )
  end

  @spec query_view(Graph.t(), [String.t()], MapSet.t()) :: map()
  def query_view(graph, touched_node_ids, expanded_node_ids \\ MapSet.new())

  def query_view(%Graph{} = graph, touched_node_ids, expanded_node_ids) do
    base_ids = Enum.filter(touched_node_ids, &Map.has_key?(graph.nodes, &1))

    visible_ids =
      expanded_node_ids
      |> Enum.reduce(base_ids, fn node_id, acc ->
        acc ++ one_hop_ids(graph, node_id)
      end)
      |> Enum.uniq()

    build_view(:query, graph, visible_ids,
      selection: %{},
      expanded_node_ids: expanded_node_ids
    )
  end

  defp build_clustered_view(graph, clusters, opts) do
    cluster_nodes = Enum.map(clusters, &serialize_cluster_node/1)
    inter_edges = build_inter_cluster_edges(graph, clusters)

    edge_counts_by_cluster =
      Enum.reduce(inter_edges, %{}, fn edge, acc ->
        acc
        |> Map.update(edge.source, 1, &(&1 + 1))
        |> Map.update(edge.target, 1, &(&1 + 1))
      end)

    nodes_with_degree =
      Enum.map(cluster_nodes, fn node ->
        %{node | degree: Map.get(edge_counts_by_cluster, node.id, 0)}
      end)

    %{
      mode: :clustered_project,
      title: "Project Graph (clustered)",
      selection: Keyword.get(opts, :selection, %{node_id: nil, session_id: nil}),
      layout_mode: :force,
      nodes: Enum.sort_by(nodes_with_degree, & &1.id),
      edges: Enum.sort_by(inter_edges, & &1.id),
      expandable_nodes: [],
      stats: clustered_stats(graph, clusters)
    }
  end

  defp serialize_cluster_node(cluster) do
    label = "#{cluster.representative_label} (#{cluster.node_count} nodes)"

    type_summary =
      cluster.type_distribution
      |> Enum.sort_by(fn {type, _count} -> type end)
      |> Enum.map_join(", ", fn {type, count} -> "#{type}: #{count}" end)

    %{
      id: cluster.id,
      label: label,
      graph_label: label,
      tooltip_label: "#{cluster.representative_label} -- #{cluster.node_count} nodes",
      tooltip_sections: [
        %{label: "Types", value: type_summary},
        %{label: "Internal edges", value: "#{cluster.internal_edge_count}"},
        %{label: "Top node", value: cluster.representative_label}
      ],
      type: :cluster,
      node_count: cluster.node_count,
      type_distribution: cluster.type_distribution,
      internal_edge_count: cluster.internal_edge_count,
      degree: 0,
      classes: ["type-cluster"],
      layer_priority: 0,
      sort_key: nil,
      details: %{}
    }
  end

  defp build_inter_cluster_edges(%Graph{} = graph, clusters) do
    cluster_lookup =
      Enum.reduce(clusters, %{}, fn cluster, acc ->
        Enum.reduce(cluster.node_ids, acc, fn node_id, inner_acc ->
          Map.put(inner_acc, node_id, cluster.id)
        end)
      end)

    graph.nodes
    |> Map.values()
    |> Enum.flat_map(&cluster_edges_for_node(&1, cluster_lookup))
    |> Enum.frequencies()
    |> Enum.map(fn {{source, target}, count} ->
      %{
        id: "#{source}:#{target}",
        source: source,
        target: target,
        type: "inter_cluster",
        weight: div(count, 2)
      }
    end)
  end

  defp cluster_edges_for_node(node, cluster_lookup) do
    case Map.get(cluster_lookup, node.id) do
      nil ->
        []

      source_cluster ->
        Enum.flat_map(node.links, &link_cluster_pairs(&1, source_cluster, cluster_lookup))
    end
  end

  defp link_cluster_pairs({_type, ids}, source_cluster, cluster_lookup) do
    ids
    |> Enum.map(&Map.get(cluster_lookup, &1))
    |> Enum.reject(&(is_nil(&1) or &1 == source_cluster))
    |> Enum.map(fn target_cluster ->
      [s, t] = Enum.sort([source_cluster, target_cluster])
      {s, t}
    end)
  end

  defp clustered_stats(%Graph{} = graph, clusters) do
    type_counts =
      clusters
      |> Enum.flat_map(fn c -> Enum.to_list(c.type_distribution) end)
      |> Enum.reduce(%{}, fn {type, count}, acc ->
        Map.update(acc, type, count, &(&1 + count))
      end)

    total_edges =
      graph.nodes
      |> Map.values()
      |> Enum.reduce(0, fn node, acc ->
        acc + Enum.reduce(node.links, 0, fn {_type, ids}, inner -> inner + MapSet.size(ids) end)
      end)
      |> div(2)

    %{
      node_count: map_size(graph.nodes),
      edge_count: total_edges,
      cluster_count: length(clusters),
      type_counts: type_counts
    }
  end

  defp build_view(mode, graph, visible_ids, opts) do
    nodes =
      visible_ids
      |> Enum.map(&Map.fetch!(graph.nodes, &1))
      |> Enum.map(&serialize_node(&1, Keyword.get(opts, :selection, %{})))

    visible_id_set = MapSet.new(visible_ids)
    edges = build_edges(graph, visible_id_set)

    %{
      mode: mode,
      title: title_for(mode),
      selection: Keyword.get(opts, :selection, %{}),
      nodes: Enum.sort_by(nodes, & &1.id),
      edges: Enum.sort_by(edges, & &1.id),
      expandable_nodes: expandable_nodes(graph, visible_id_set),
      stats: stats(nodes, edges),
      layout_mode: Keyword.get(opts, :layout_mode, default_layout(mode))
    }
  end

  defp serialize_node(node, selection) do
    serialized = Serializer.node(node)
    selected_id = Map.get(selection, :node_id)
    type_class = "type-#{serialized.type}"
    selected_class = if serialized.id == selected_id, do: ["is-selected"], else: []
    label = node_label(serialized)

    %{
      id: serialized.id,
      label: label,
      graph_label: label,
      tooltip_label: tooltip_label(serialized, label),
      tooltip_sections: tooltip_sections(serialized),
      type: String.to_existing_atom(serialized.type),
      degree: link_degree(serialized.links),
      classes: selected_class ++ [type_class],
      details: details_sections(serialized),
      layer_priority: layer_priority(serialized.type),
      sort_key: sort_key(node)
    }
  end

  defp build_edges(graph, visible_id_set) do
    graph.nodes
    |> Map.values()
    |> Enum.flat_map(&node_edges(&1, visible_id_set))
    |> Enum.uniq_by(& &1.id)
  end

  defp node_edges(node, visible_id_set) do
    if MapSet.member?(visible_id_set, node.id) do
      Enum.flat_map(node.links, &link_edges(node.id, &1, visible_id_set))
    else
      []
    end
  end

  defp link_edges(node_id, {type, ids}, visible_id_set) do
    ids
    |> Enum.filter(&MapSet.member?(visible_id_set, &1))
    |> Enum.map(fn linked_id ->
      [source, target] = Enum.sort([node_id, linked_id])
      %{id: "#{source}:#{target}", source: source, target: target, type: type}
    end)
  end

  defp centered_visible_ids(graph, node_id, expanded_node_ids) do
    [node_id]
    |> Kernel.++(one_hop_ids(graph, node_id))
    |> Kernel.++(
      Enum.flat_map(expanded_node_ids, fn expanded_id ->
        one_hop_ids(graph, expanded_id)
      end)
    )
  end

  defp one_hop_ids(graph, node_id) do
    case Map.get(graph.nodes, node_id) do
      nil -> []
      node -> [node.id | linked_ids(node)]
    end
  end

  defp visible_ids(graph), do: Map.keys(graph.nodes)

  defp expandable_nodes(graph, visible_id_set) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      MapSet.member?(visible_id_set, node.id) and
        Enum.any?(linked_ids(node), &(not MapSet.member?(visible_id_set, &1)))
    end)
    |> Enum.map(fn node ->
      serialized = Serializer.node(node)
      %{id: serialized.id, label: node_label(serialized)}
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp stats(nodes, edges) do
    %{
      node_count: length(nodes),
      edge_count: length(edges),
      type_counts: Enum.frequencies_by(nodes, & &1.type)
    }
  end

  defp node_label(node), do: Serializer.node_label(node)

  defp tooltip_label(%{observation: observation} = serialized, _label)
       when is_binary(observation) do
    [
      "Observation: #{observation}",
      action_line(Map.get(serialized, :action)),
      reward_line(Map.get(serialized, :reward))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tooltip_label(%{type: "source", plain_text: plain_text} = serialized, _label)
       when is_binary(plain_text) do
    [
      plain_text,
      episode_line(Map.get(serialized, :episode_id), Map.get(serialized, :step_index))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp tooltip_label(%{type: "procedural", instruction: instruction}, _label)
       when is_binary(instruction) do
    instruction
  end

  defp tooltip_label(%{type: "semantic", proposition: proposition}, _label)
       when is_binary(proposition) do
    proposition
  end

  defp tooltip_label(%{type: "subgoal", description: description}, _label)
       when is_binary(description) do
    description
  end

  defp tooltip_label(%{type: "intent", description: description}, _label)
       when is_binary(description) do
    description
  end

  defp tooltip_label(%{episode_id: episode_id, step_index: step_index}, _label) do
    "Episode #{episode_id}, step #{step_index}"
  end

  defp tooltip_label(_serialized, label), do: label

  defp tooltip_sections(%{observation: observation} = serialized) when is_binary(observation) do
    Enum.reject(
      [
        %{label: "Observation", value: observation},
        section("Action", Map.get(serialized, :action)),
        section("Subgoal", Map.get(serialized, :subgoal)),
        section("Reward", format_reward(Map.get(serialized, :reward)))
      ],
      &is_nil/1
    )
  end

  defp tooltip_sections(%{type: "procedural"} = s) do
    Enum.reject(
      [
        section("Instruction", s[:instruction]),
        section("Condition", s[:condition]),
        section("Expected Outcome", s[:expected_outcome]),
        section("Return Score", s[:return_score] && format_reward(s[:return_score]))
      ],
      &is_nil/1
    )
  end

  defp tooltip_sections(%{type: "semantic"} = s) do
    Enum.reject(
      [
        section("Proposition", s[:proposition]),
        section("Confidence", s[:confidence] && format_reward(s[:confidence]))
      ],
      &is_nil/1
    )
  end

  defp tooltip_sections(%{type: "subgoal"} = s) do
    Enum.reject(
      [
        section("Description", s[:description]),
        section("Parent Goal", s[:parent_goal])
      ],
      &is_nil/1
    )
  end

  defp tooltip_sections(%{type: "intent"} = s) do
    Enum.reject([section("Description", s[:description])], &is_nil/1)
  end

  defp tooltip_sections(%{type: "tag"} = s) do
    Enum.reject([section("Label", s[:label])], &is_nil/1)
  end

  defp tooltip_sections(%{type: "source"} = serialized) do
    Enum.reject(
      [
        section("Plain Text", Map.get(serialized, :plain_text)),
        section("Episode", Map.get(serialized, :episode_id)),
        section("Step", serialized[:step_index] && Integer.to_string(serialized[:step_index])),
        section("Created", serialized[:created_at] && format_timestamp(serialized[:created_at]))
      ],
      &is_nil/1
    )
  end

  defp tooltip_sections(_serialized), do: nil

  defp details_sections(%{type: "episodic"} = s) do
    Enum.reject(
      [
        section("Observation", s[:observation]),
        section("Action", s[:action]),
        section("State", s[:state]),
        section("Subgoal", s[:subgoal]),
        section("Reward", s[:reward] && format_reward(s[:reward])),
        section("Trajectory", s[:trajectory_id])
      ],
      &is_nil/1
    )
  end

  defp details_sections(%{type: "procedural"} = s) do
    Enum.reject(
      [
        section("Instruction", s[:instruction]),
        section("Condition", s[:condition]),
        section("Expected Outcome", s[:expected_outcome]),
        section("Return Score", s[:return_score] && format_reward(s[:return_score]))
      ],
      &is_nil/1
    )
  end

  defp details_sections(%{type: "semantic"} = s) do
    Enum.reject(
      [
        section("Proposition", s[:proposition]),
        section("Confidence", s[:confidence] && format_reward(s[:confidence]))
      ],
      &is_nil/1
    )
  end

  defp details_sections(%{type: "subgoal"} = s) do
    Enum.reject(
      [
        section("Description", s[:description]),
        section("Parent Goal", s[:parent_goal])
      ],
      &is_nil/1
    )
  end

  defp details_sections(%{type: "intent"} = s) do
    Enum.reject([section("Description", s[:description])], &is_nil/1)
  end

  defp details_sections(%{type: "tag"} = s) do
    Enum.reject([section("Label", s[:label])], &is_nil/1)
  end

  defp details_sections(%{type: "source"} = s) do
    Enum.reject(
      [
        section("Plain Text", s[:plain_text]),
        section("Episode", s[:episode_id]),
        section("Step", s[:step_index] && Integer.to_string(s[:step_index])),
        section("Created", s[:created_at] && format_timestamp(s[:created_at]))
      ],
      &is_nil/1
    )
  end

  defp details_sections(_), do: []

  defp section(_label, nil), do: nil
  defp section(_label, ""), do: nil
  defp section(label, value), do: %{label: label, value: value}

  defp action_line(nil), do: nil
  defp action_line(""), do: nil
  defp action_line(action), do: "Action: #{action}"

  defp episode_line(nil, _step), do: nil

  defp episode_line(episode_id, step_index),
    do: "Episode #{episode_id}, step #{step_index || "?"}"

  defp reward_line(nil), do: nil
  defp reward_line(reward), do: "Reward: #{format_reward(reward)}"

  defp format_reward(reward) when is_float(reward),
    do: :erlang.float_to_binary(reward, decimals: 1)

  defp format_reward(reward) when is_integer(reward), do: Integer.to_string(reward)
  defp format_reward(reward) when is_binary(reward), do: reward
  defp format_reward(reward), do: to_string(reward)

  defp title_for(:focused), do: "Focused Graph"
  defp title_for(:project), do: "Project Graph"
  defp title_for(:query), do: "Query Graph"
  defp title_for(:session), do: "Session Graph"

  defp default_layout(_mode), do: :force

  defp layer_priority("intent"), do: 0
  defp layer_priority("subgoal"), do: 1
  defp layer_priority("semantic"), do: 2
  defp layer_priority("procedural"), do: 2
  defp layer_priority("episodic"), do: 3
  defp layer_priority("tag"), do: 4
  defp layer_priority("source"), do: 4
  defp layer_priority(_type), do: 3

  defp sort_key(%{created_at: %DateTime{} = dt}), do: DateTime.to_iso8601(dt)
  defp sort_key(%{id: id}), do: id

  defp linked_ids(node) do
    Enum.flat_map(node.links, fn {_type, ids} -> MapSet.to_list(ids) end)
  end

  defp link_degree(links) when is_map(links) do
    Enum.reduce(links, 0, fn {_type, ids}, acc -> acc + length(ids) end)
  end

  defp link_degree(_), do: 0

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_timestamp(_), do: nil
end
