defmodule GingkoWeb.Api.NodeController do
  use GingkoWeb, :controller

  action_fallback GingkoWeb.Api.FallbackController

  def show(conn, %{"project_id" => project_id, "node_id" => node_id}) do
    case Gingko.Memory.get_node(%{project_id: project_id, node_id: node_id}) do
      {:ok, %{node: nil}} ->
        {:error, %{code: :node_not_found, message: "node #{node_id} not found"}}

      {:ok, result} ->
        json(conn, result)

      {:error, _} = error ->
        error
    end
  end
end
