defmodule Gingko.MCP.Tools.GetCluster do
  @moduledoc """
  MCP tool that fetches a single cluster summary by slug or tag_node_id.
  """

  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse
  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterSummary

  def name, do: "get_cluster"

  def description do
    """
    Fetch one cluster summary by slug (human-readable) or by tag_node_id (UUID). \
    Returns the stored headline, body content, memory counts, and frontmatter. \
    Use the cluster index in the session primer to find relevant slugs.
    """
  end

  schema do
    field(:project_id, :string, required: true, description: "The project identifier.")

    field(:slug, :string,
      description: "Cluster slug as shown in the session-primer cluster index."
    )

    field(:tag_node_id, :string, description: "Cluster tag UUID. Alternative to `slug`.")
  end

  def execute(args, frame) do
    project_id = args[:project_id] || args["project_id"]
    slug = args[:slug] || args["slug"]
    tag_node_id = args[:tag_node_id] || args["tag_node_id"]

    ToolResponse.from_result(fetch(project_id, slug, tag_node_id), frame)
  end

  defp fetch(project_id, slug, nil) when is_binary(slug) do
    resolve(Summaries.get_cluster_by_slug(project_id, slug), "slug=#{slug}")
  end

  defp fetch(project_id, nil, tag_node_id) when is_binary(tag_node_id) do
    resolve(Summaries.get_cluster(project_id, tag_node_id), "tag_node_id=#{tag_node_id}")
  end

  defp fetch(project_id, slug, tag_node_id) when is_binary(slug) and is_binary(tag_node_id) do
    resolve(
      Summaries.get_cluster_by_slug(project_id, slug),
      "slug=#{slug} or tag_node_id=#{tag_node_id}"
    )
  end

  defp fetch(_project_id, _slug, _tag_node_id) do
    {:error,
     %{
       code: :invalid_params,
       message: "one of `slug` or `tag_node_id` is required"
     }}
  end

  defp resolve(%ClusterSummary{} = cluster, _identifier), do: {:ok, cluster}

  defp resolve(nil, identifier) do
    {:error,
     %{
       code: :cluster_not_found,
       message: "cluster not found for #{identifier}"
     }}
  end
end
