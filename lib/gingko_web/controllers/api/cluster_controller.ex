defmodule GingkoWeb.Api.ClusterController do
  @moduledoc false

  use GingkoWeb, :controller

  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterSummary

  action_fallback GingkoWeb.Api.FallbackController

  def show(conn, %{"project_id" => project_id, "slug" => slug}) do
    case Summaries.get_cluster_by_slug(project_id, slug) do
      %ClusterSummary{} = cluster ->
        json(conn, serialize(cluster))

      nil ->
        {:error,
         %{
           code: :cluster_not_found,
           message: "cluster not found for slug=#{slug}"
         }}
    end
  end

  defp serialize(%ClusterSummary{} = cluster) do
    cluster
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end
end
