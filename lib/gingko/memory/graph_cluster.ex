defmodule Gingko.Memory.GraphCluster do
  @moduledoc """
  Graph clustering via connected components and label propagation.

  Owns an ETS table for caching cluster results keyed by
  `{project_id, version}`. The GenServer exists solely to own the
  ETS table -- all reads and writes go directly through ETS.

  Write safety: Mnemosyne dispatches events sequentially per repo,
  so concurrent writes for the same project_id cannot occur.
  """

  use GenServer

  alias Gingko.Memory.Serializer
  alias Mnemosyne.Graph
  alias Mnemosyne.Graph.Node, as: NodeProtocol
  alias Mnemosyne.Graph.Node.Helpers, as: NodeHelpers

  @table __MODULE__
  @version_table Module.concat(__MODULE__, :versions)

  @max_cluster_size 50
  @min_cluster_size 3
  @label_propagation_iterations 5
  @clustering_threshold 100

  # -- Public API ----------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Clusters a graph if it exceeds the node threshold.
  Returns `:flat` for small graphs, `{:clustered, clusters}` otherwise.
  """
  @spec cluster(Graph.t()) :: {:clustered, [map()]} | :flat
  def cluster(%Graph{nodes: nodes}) when map_size(nodes) <= @clustering_threshold, do: :flat

  def cluster(%Graph{} = graph) do
    {:clustered, compute_clusters(graph)}
  end

  @doc """
  Pure clustering algorithm: connected components, label propagation
  for large components, and small-component merging.
  """
  @spec compute_clusters(Graph.t()) :: [map()]
  def compute_clusters(%Graph{nodes: nodes}) when map_size(nodes) == 0, do: []

  def compute_clusters(%Graph{} = graph) do
    adjacency = build_adjacency(graph)
    components = connected_components(adjacency)

    {small, regular} =
      components
      |> Enum.flat_map(&subdivide_component(&1, adjacency))
      |> Enum.split_with(fn node_ids -> MapSet.size(node_ids) < @min_cluster_size end)

    merged = merge_small_components(small, regular, adjacency)

    Enum.map(merged, &build_cluster_map(&1, graph, adjacency))
  end

  @spec bump_version(String.t()) :: non_neg_integer()
  def bump_version(project_id) when is_binary(project_id) do
    new_version = :ets.update_counter(@version_table, project_id, {2, 1}, {project_id, 0})
    purge_stale_cache(project_id, new_version)
    new_version
  end

  @spec get_cached(String.t()) :: {:ok, {non_neg_integer(), [map()]}} | :miss
  def get_cached(project_id) when is_binary(project_id) do
    version = current_version(project_id)

    case :ets.lookup(@table, {project_id, version}) do
      [{_, clusters}] -> {:ok, {version, clusters}}
      [] -> :miss
    end
  end

  @spec put_cached(String.t(), [map()]) :: :ok
  def put_cached(project_id, clusters) when is_binary(project_id) do
    version = current_version(project_id)
    purge_stale_cache(project_id, version)
    :ets.insert(@table, {{project_id, version}, clusters})
    :ok
  end

  # -- GenServer callbacks -------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@version_table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  # -- Adjacency graph construction ----------------------------------------

  defp build_adjacency(%Graph{nodes: nodes}) do
    node_id_set = MapSet.new(Map.keys(nodes))

    Map.new(nodes, fn {id, node} ->
      neighbors =
        node
        |> NodeHelpers.all_linked_ids()
        |> MapSet.intersection(node_id_set)

      {id, neighbors}
    end)
  end

  # -- Connected components (BFS) ------------------------------------------

  defp connected_components(adjacency) do
    {components, _visited} =
      adjacency
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce({[], MapSet.new()}, fn node_id, {comps, visited} ->
        if MapSet.member?(visited, node_id) do
          {comps, visited}
        else
          component = bfs(adjacency, node_id)
          {[component | comps], MapSet.union(visited, component)}
        end
      end)

    components
  end

  defp bfs(adjacency, start_id) do
    bfs_loop(adjacency, :queue.from_list([start_id]), MapSet.new([start_id]))
  end

  defp bfs_loop(adjacency, queue, visited) do
    case :queue.out(queue) do
      {:empty, _} ->
        visited

      {{:value, current}, rest} ->
        neighbors = Map.get(adjacency, current, MapSet.new())

        {new_queue, new_visited} =
          neighbors
          |> Enum.sort()
          |> Enum.reduce({rest, visited}, fn neighbor, {q, v} ->
            if MapSet.member?(v, neighbor) do
              {q, v}
            else
              {:queue.in(neighbor, q), MapSet.put(v, neighbor)}
            end
          end)

        bfs_loop(adjacency, new_queue, new_visited)
    end
  end

  # -- Label propagation ---------------------------------------------------

  defp subdivide_component(node_ids, adjacency) when is_struct(node_ids, MapSet) do
    if MapSet.size(node_ids) <= @max_cluster_size do
      [node_ids]
    else
      label_propagation(node_ids, adjacency)
    end
  end

  defp label_propagation(node_ids, adjacency) do
    sorted_ids = node_ids |> MapSet.to_list() |> Enum.sort()
    initial_labels = Map.new(sorted_ids, fn id -> {id, id} end)

    final_labels =
      Enum.reduce(1..@label_propagation_iterations, initial_labels, fn _iter, labels ->
        propagation_step(sorted_ids, adjacency, labels)
      end)

    final_labels
    |> Enum.group_by(fn {_id, label} -> label end, fn {id, _label} -> id end)
    |> Map.values()
    |> Enum.map(&MapSet.new/1)
  end

  defp propagation_step(sorted_ids, adjacency, labels) do
    Enum.reduce(sorted_ids, labels, fn node_id, acc ->
      neighbors = Map.get(adjacency, node_id, MapSet.new())

      neighbor_labels =
        neighbors
        |> MapSet.to_list()
        |> Enum.map(&Map.get(acc, &1))
        |> Enum.reject(&is_nil/1)

      case neighbor_labels do
        [] ->
          acc

        _ ->
          most_common =
            neighbor_labels
            |> Enum.frequencies()
            |> Enum.max_by(fn {label, count} -> {count, label} end)
            |> elem(0)

          Map.put(acc, node_id, most_common)
      end
    end)
  end

  # -- Small component merging ---------------------------------------------

  defp merge_small_components([], regular, _adjacency), do: regular

  defp merge_small_components(small_groups, regular, adjacency) do
    case regular do
      [] ->
        [Enum.reduce(small_groups, MapSet.new(), &MapSet.union/2)]

      _ ->
        Enum.reduce(small_groups, regular, fn small_set, clusters ->
          best_index = find_most_connected_cluster(small_set, clusters, adjacency)
          List.update_at(clusters, best_index, &MapSet.union(&1, small_set))
        end)
    end
  end

  defp find_most_connected_cluster(small_set, clusters, adjacency) do
    clusters
    |> Enum.with_index()
    |> Enum.max_by(fn {cluster, _idx} ->
      cross_edges(small_set, cluster, adjacency)
    end)
    |> elem(1)
  end

  defp cross_edges(set_a, set_b, adjacency) do
    Enum.reduce(set_a, 0, fn node_id, count ->
      neighbors = Map.get(adjacency, node_id, MapSet.new())
      count + MapSet.size(MapSet.intersection(neighbors, set_b))
    end)
  end

  # -- Cluster map construction --------------------------------------------

  defp build_cluster_map(node_ids, %Graph{} = graph, adjacency) do
    %{
      id: cluster_id(node_ids),
      node_ids: node_ids,
      node_count: MapSet.size(node_ids),
      type_distribution: type_distribution(node_ids, graph),
      representative_label: representative_label(node_ids, graph, adjacency),
      internal_edge_count: internal_edge_count(node_ids, adjacency)
    }
  end

  @doc false
  def cluster_id(node_ids) do
    hash =
      node_ids
      |> Enum.sort()
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "cluster:" <> hash
  end

  defp type_distribution(node_ids, %Graph{nodes: nodes}) do
    node_ids
    |> Enum.map(fn id -> Map.fetch!(nodes, id) end)
    |> Enum.frequencies_by(&NodeProtocol.node_type/1)
  end

  defp representative_label(node_ids, %Graph{nodes: nodes}, adjacency) do
    {best_id, _degree} =
      node_ids
      |> Enum.map(fn id ->
        degree =
          adjacency
          |> Map.get(id, MapSet.new())
          |> MapSet.size()

        {id, degree}
      end)
      |> Enum.max_by(fn {id, degree} -> {degree, id} end)

    node = Map.fetch!(nodes, best_id)
    node_label(node)
  end

  defp internal_edge_count(node_ids, adjacency) do
    Enum.reduce(node_ids, 0, fn node_id, count ->
      neighbors = Map.get(adjacency, node_id, MapSet.new())
      count + MapSet.size(MapSet.intersection(neighbors, node_ids))
    end)
    |> div(2)
  end

  defp node_label(node), do: Serializer.node_label(node)

  # -- Version helpers -----------------------------------------------------

  defp current_version(project_id) do
    case :ets.lookup(@version_table, project_id) do
      [{_, version}] -> version
      [] -> 0
    end
  end

  defp purge_stale_cache(project_id, current_version) do
    :ets.select_delete(@table, [
      {{{project_id, :"$1"}, :_}, [{:<, :"$1", current_version}], [true]}
    ])
  end
end
