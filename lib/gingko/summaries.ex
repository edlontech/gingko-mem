defmodule Gingko.Summaries do
  @moduledoc """
  Context for derived-memory artifacts (principal sections, cluster summaries,
  membership deltas). Raw memories stay in Mnemosyne; this context owns the
  SQLite-backed summary layer only.
  """

  import Ecto.Query

  alias Gingko.Repo
  alias Gingko.Summaries.ClusterMembershipDelta
  alias Gingko.Summaries.ClusterSummary
  alias Gingko.Summaries.Config
  alias Gingko.Summaries.Playbook
  alias Gingko.Summaries.PrimerRenderer
  alias Gingko.Summaries.PrincipalMemorySection

  @section_kinds PrincipalMemorySection.kinds()

  @doc """
  Seeds the static playbook row for a project. Idempotent via upsert.
  """
  @spec seed_playbook(String.t()) ::
          {:ok, PrincipalMemorySection.t()} | {:error, Ecto.Changeset.t()}
  def seed_playbook(project_key) when is_binary(project_key) do
    upsert_section(%{
      project_key: project_key,
      kind: "playbook",
      content: Playbook.markdown()
    })
  end

  @doc """
  Renders the composed session-primer markdown for a project.

  Options:
    * `:recent_count` - number of raw memories to include in the recent tail
      (defaults to `Config.session_primer_recent_count/0`).
  """
  @spec render_primer(String.t(), keyword()) :: {:ok, String.t()}
  def render_primer(project_key, opts \\ []) when is_binary(project_key) do
    recent_count = Keyword.get(opts, :recent_count, Config.session_primer_recent_count())

    playbook = section_content(project_key, "playbook") || Playbook.markdown()
    charter = section_content(project_key, "charter")
    state = get_section(project_key, "state")
    clusters = list_clusters(project_key)
    recent = fetch_recent_memories(project_key, recent_count)

    {:ok, PrimerRenderer.render(playbook, charter, state, clusters, recent)}
  end

  defp section_content(project_key, kind) do
    case get_section(project_key, kind) do
      %PrincipalMemorySection{content: content} -> content
      nil -> nil
    end
  end

  defp fetch_recent_memories(project_key, recent_count) do
    case Gingko.Memory.latest_memories(%{project_id: project_key, top_k: recent_count}) do
      {:ok, %{memories: memories}} -> memories
      {:error, _} -> []
    end
  end

  @spec get_section(String.t(), String.t()) :: PrincipalMemorySection.t() | nil
  def get_section(project_key, kind) when kind in @section_kinds do
    Repo.get_by(PrincipalMemorySection, project_key: project_key, kind: kind)
  end

  @spec list_sections(String.t()) :: [PrincipalMemorySection.t()]
  def list_sections(project_key) do
    Repo.all(from(s in PrincipalMemorySection, where: s.project_key == ^project_key))
  end

  # Uses a find-or-new pattern instead of `Repo.insert(on_conflict: ...)`
  # because `ecto_sqlite3` with `:binary_id` primary keys returns the
  # client-generated UUID from the insert attempt rather than the stored row's
  # UUID on the UPDATE branch of `ON CONFLICT`, which breaks id stability.
  @spec upsert_section(map()) ::
          {:ok, PrincipalMemorySection.t()} | {:error, Ecto.Changeset.t()}
  def upsert_section(attrs) do
    project_key = Map.get(attrs, :project_key) || Map.get(attrs, "project_key")
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind")

    existing =
      if is_binary(project_key) and kind in @section_kinds do
        Repo.get_by(PrincipalMemorySection, project_key: project_key, kind: kind)
      end

    case existing do
      %PrincipalMemorySection{} = section ->
        section
        |> PrincipalMemorySection.changeset(attrs)
        |> Repo.update()

      nil ->
        %PrincipalMemorySection{}
        |> PrincipalMemorySection.changeset(attrs)
        |> Repo.insert()
    end
  end

  @doc """
  Upserts the charter section with respect to the `locked` flag.

  Returns `{:error, %{code: :invalid_params}}` when content is empty, and
  `{:error, %{code: :charter_locked}}` when the existing row is locked.
  Otherwise delegates to `upsert_section/1`.
  """
  @spec set_charter(String.t(), String.t()) ::
          {:ok, PrincipalMemorySection.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, %{code: atom(), message: String.t()}}
  def set_charter(_project_key, content) when content in [nil, ""] do
    {:error, %{code: :invalid_params, message: "`content` must be a non-empty string"}}
  end

  def set_charter(project_key, content) when is_binary(project_key) and is_binary(content) do
    case get_section(project_key, "charter") do
      %PrincipalMemorySection{locked: true} ->
        {:error,
         %{
           code: :charter_locked,
           message: "charter is locked and cannot be overwritten"
         }}

      _ ->
        upsert_section(%{project_key: project_key, kind: "charter", content: content})
    end
  end

  @spec get_cluster(String.t(), String.t()) :: ClusterSummary.t() | nil
  def get_cluster(project_key, tag_node_id) do
    Repo.get_by(ClusterSummary, project_key: project_key, tag_node_id: tag_node_id)
  end

  @spec get_cluster_by_slug(String.t(), String.t()) :: ClusterSummary.t() | nil
  def get_cluster_by_slug(project_key, slug) do
    Repo.one(
      from(c in ClusterSummary,
        where: c.project_key == ^project_key and c.slug == ^slug
      )
    )
  end

  @spec list_clusters(String.t()) :: [ClusterSummary.t()]
  def list_clusters(project_key) do
    Repo.all(
      from(c in ClusterSummary,
        where: c.project_key == ^project_key,
        order_by: [desc: c.memory_count, desc: c.updated_at]
      )
    )
  end

  @spec list_dirty_clusters(String.t()) :: [ClusterSummary.t()]
  def list_dirty_clusters(project_key) do
    Repo.all(
      from(c in ClusterSummary,
        where: c.project_key == ^project_key and c.dirty == true and c.locked == false,
        order_by: [asc: c.dirty_since]
      )
    )
  end

  # Uses a find-or-new pattern instead of `Repo.insert(on_conflict: ...)`
  # because `ecto_sqlite3` with `:binary_id` primary keys returns the
  # client-generated UUID from the insert attempt rather than the stored row's
  # UUID on the UPDATE branch of `ON CONFLICT`, which breaks id stability.
  @spec upsert_cluster(map()) :: {:ok, ClusterSummary.t()} | {:error, Ecto.Changeset.t()}
  def upsert_cluster(attrs) do
    project_key = Map.get(attrs, :project_key) || Map.get(attrs, "project_key")
    tag_node_id = Map.get(attrs, :tag_node_id) || Map.get(attrs, "tag_node_id")

    existing =
      if is_binary(project_key) and is_binary(tag_node_id) do
        Repo.get_by(ClusterSummary, project_key: project_key, tag_node_id: tag_node_id)
      end

    case existing do
      %ClusterSummary{} = cluster ->
        cluster
        |> ClusterSummary.changeset(attrs)
        |> Repo.update()

      nil ->
        %ClusterSummary{}
        |> ClusterSummary.changeset(attrs)
        |> Repo.insert()
    end
  end

  @spec update_cluster(ClusterSummary.t(), map()) ::
          {:ok, ClusterSummary.t()} | {:error, Ecto.Changeset.t()}
  def update_cluster(%ClusterSummary{} = cluster, attrs) do
    cluster
    |> ClusterSummary.changeset(attrs)
    |> Repo.update()
  end

  @spec append_membership_delta(map()) ::
          {:ok, ClusterMembershipDelta.t()} | {:error, Ecto.Changeset.t()}
  def append_membership_delta(attrs) do
    %ClusterMembershipDelta{}
    |> ClusterMembershipDelta.changeset(attrs)
    |> Repo.insert()
  end

  @spec deltas_since(String.t(), String.t(), DateTime.t() | nil) :: [ClusterMembershipDelta.t()]
  def deltas_since(project_key, tag_node_id, nil) do
    Repo.all(
      from(d in ClusterMembershipDelta,
        where: d.project_key == ^project_key and d.tag_node_id == ^tag_node_id,
        order_by: [asc: d.observed_at]
      )
    )
  end

  def deltas_since(project_key, tag_node_id, %DateTime{} = since) do
    Repo.all(
      from(d in ClusterMembershipDelta,
        where:
          d.project_key == ^project_key and d.tag_node_id == ^tag_node_id and
            d.observed_at > ^since,
        order_by: [asc: d.observed_at]
      )
    )
  end

  @spec delete_deltas_up_to(String.t(), String.t(), DateTime.t()) ::
          {non_neg_integer(), nil | [term()]}
  def delete_deltas_up_to(project_key, tag_node_id, %DateTime{} = cutoff) do
    Repo.delete_all(
      from(d in ClusterMembershipDelta,
        where:
          d.project_key == ^project_key and d.tag_node_id == ^tag_node_id and
            d.observed_at <= ^cutoff
      )
    )
  end

  @doc """
  Finalizes a cluster regeneration: updates content, bumps `regen_count`, clears
  dirty flags, sets `last_generated_at`, and stamps the frontmatter with `mode`
  and `latency_ms`.
  """
  @spec finalize_cluster_regen(ClusterSummary.t(), map(), atom(), non_neg_integer(), DateTime.t()) ::
          {:ok, ClusterSummary.t()} | {:error, Ecto.Changeset.t()}
  def finalize_cluster_regen(
        %ClusterSummary{} = cluster,
        result,
        mode,
        duration_ms,
        %DateTime{} = now
      ) do
    frontmatter =
      result
      |> Map.get(:frontmatter, %{})
      |> stringify_keys()
      |> Map.put("mode", to_string(mode))
      |> Map.put("latency_ms", duration_ms)

    update_cluster(cluster, %{
      headline: Map.get(result, :headline),
      content: Map.get(result, :content, ""),
      dirty: false,
      dirty_since: nil,
      last_generated_at: now,
      regen_count: cluster.regen_count + 1,
      frontmatter: frontmatter
    })
  end

  @doc """
  Finalizes a principal state regeneration: upserts the `:state` section row
  with the generated content and stamps the frontmatter with the list of
  tag_node_ids that informed the summary.
  """
  @spec finalize_state_regen(String.t(), String.t(), map(), [ClusterSummary.t()]) ::
          {:ok, PrincipalMemorySection.t()} | {:error, Ecto.Changeset.t()}
  def finalize_state_regen(project_key, content, frontmatter, clusters)
      when is_binary(project_key) and is_binary(content) and is_list(clusters) do
    source_cluster_ids = Enum.map(clusters, & &1.tag_node_id)

    fm =
      frontmatter
      |> stringify_keys()
      |> Map.put("source_cluster_ids", source_cluster_ids)

    upsert_section(%{
      project_key: project_key,
      kind: "state",
      content: content,
      frontmatter: fm
    })
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {key_to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp key_to_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_to_string(k) when is_binary(k), do: k
end
