defmodule GingkoWeb.Api.RefreshPrincipalMemoryController do
  use GingkoWeb, :controller

  alias Gingko.Summaries.Refresh

  action_fallback GingkoWeb.Api.FallbackController

  def create(conn, %{"project_id" => project_id} = params) do
    scope = Map.get(params, "scope", "all")
    cluster_slug = params["cluster_slug"]

    with {:ok, result} <- Refresh.run(project_id, scope, cluster_slug) do
      json(conn, result)
    end
  end
end
