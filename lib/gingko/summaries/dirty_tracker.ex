defmodule Gingko.Summaries.DirtyTracker do
  @moduledoc """
  Telemetry handler that keeps `cluster_summaries` rows fresh as memories are
  appended.

  Listens on `[:mnemosyne, :memory, :appended]` and, for each tag linked to the
  newly appended memory, admits the tag to the hot-tag set when:

    * a cluster row already exists for that tag, OR
    * the cluster table for the project has fewer than
      `Gingko.Summaries.Config.hot_tags_k/0` rows, OR
    * the tag's current memory count exceeds the minimum memory count across
      the existing cluster rows.

  For admitted tags the tracker upserts the cluster row (marking it dirty),
  appends a `cluster_membership_deltas` row, and enqueues the
  `Gingko.Summaries.ClusterWorker`. The handler no-ops when
  `Gingko.Summaries.Config.enabled?/0` is false.

  `handle_event/4` wraps its body in a broad `rescue` on purpose: `:telemetry`
  permanently detaches a handler on any uncaught exception, which would
  silently disable cluster tracking until VM restart.
  """

  require Logger

  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.Config

  @handler_id {__MODULE__, :mnemosyne_appended}
  @event [:mnemosyne, :memory, :appended]

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @spec handle_event(
          event_name :: [atom()],
          measurements :: map(),
          metadata :: map(),
          config :: term()
        ) :: :ok
  def handle_event(@event, _measurements, metadata, _config) do
    if Config.enabled?() do
      handle(metadata)
    else
      :ok
    end
  rescue
    error ->
      Logger.warning(
        "DirtyTracker handler error for project=#{inspect(Map.get(metadata, :project_key))} " <>
          "node=#{inspect(get_in(metadata, [:node, :id]))}: " <>
          "#{Exception.message(error)}\n" <> Exception.format_stacktrace(__STACKTRACE__)
      )

      :ok
  end

  defp handle(%{project_key: project_key, node: %{id: node_id}, linked_tags: tags})
       when is_binary(project_key) and is_binary(node_id) and is_list(tags) and tags != [] do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    clusters = Summaries.list_clusters(project_key)

    _final_clusters =
      Enum.reduce(tags, clusters, fn tag, acc ->
        admit_tag(project_key, node_id, tag, acc, observed_at)
      end)

    :ok
  end

  defp handle(_metadata), do: :ok

  defp admit_tag(project_key, node_id, %{id: tag_id} = tag, clusters, observed_at)
       when is_binary(tag_id) do
    tag_count = Map.get(tag, :memory_count, 0)
    label = Map.get(tag, :label)

    if admit?(clusters, tag_id, tag_count) do
      case upsert_cluster(project_key, tag_id, label, tag_count, observed_at) do
        {:ok, cluster} ->
          record_delta(project_key, tag_id, node_id, observed_at)
          ClusterWorker.enqueue(%{project_key: project_key, tag_node_id: tag_id})
          replace_cluster(clusters, cluster)

        {:error, changeset} ->
          Logger.warning(
            "DirtyTracker failed to upsert cluster for #{project_key}/#{tag_id}: #{inspect(changeset.errors)}"
          )

          clusters
      end
    else
      clusters
    end
  end

  defp admit_tag(_project_key, _node_id, _tag, clusters, _observed_at), do: clusters

  defp admit?(clusters, tag_id, tag_count) do
    cond do
      Enum.any?(clusters, &(&1.tag_node_id == tag_id)) ->
        true

      length(clusters) < Config.hot_tags_k() ->
        true

      true ->
        tag_count > min_memory_count(clusters)
    end
  end

  defp min_memory_count([]), do: 0

  defp min_memory_count(clusters) do
    clusters |> Enum.map(& &1.memory_count) |> Enum.min()
  end

  defp upsert_cluster(project_key, tag_id, label, tag_count, observed_at) do
    attrs = %{
      project_key: project_key,
      tag_node_id: tag_id,
      tag_label: cluster_label(label, tag_id),
      slug: slugify(label, tag_id),
      memory_count: tag_count,
      dirty: true,
      dirty_since: observed_at
    }

    Summaries.upsert_cluster(attrs)
  rescue
    error in [Ecto.ConstraintError, Ecto.StaleEntryError] ->
      Logger.warning(
        "DirtyTracker persistence error upserting cluster #{project_key}/#{tag_id}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  defp record_delta(project_key, tag_id, node_id, observed_at) do
    Summaries.append_membership_delta(%{
      project_key: project_key,
      tag_node_id: tag_id,
      memory_node_id: node_id,
      observed_at: observed_at
    })
  rescue
    error in [Ecto.ConstraintError] ->
      Logger.warning(
        "DirtyTracker persistence error appending delta #{project_key}/#{tag_id}: #{Exception.message(error)}"
      )

      {:error, error}
  end

  defp replace_cluster(clusters, %{tag_node_id: tag_id} = cluster) do
    case Enum.split_with(clusters, &(&1.tag_node_id == tag_id)) do
      {[], rest} -> [cluster | rest]
      {[_existing], rest} -> [cluster | rest]
    end
  end

  defp cluster_label(label, _tag_id) when is_binary(label) and label != "", do: label
  defp cluster_label(_label, tag_id), do: tag_id

  defp slugify(label, tag_id) when is_binary(label) do
    slug =
      label
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: tag_id, else: slug
  end

  defp slugify(_label, tag_id), do: tag_id
end
