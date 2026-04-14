defmodule GingkoWeb.Api.ProjectController do
  use GingkoWeb, :controller

  action_fallback GingkoWeb.Api.FallbackController

  def index(conn, _params) do
    result = Gingko.Memory.list_projects()
    json(conn, result)
  end

  def open(conn, %{"project_id" => project_id}) do
    with {:ok, result} <- Gingko.Memory.open_project(project_id) do
      {already_open, result} = Map.pop(result, :already_open?)
      result = Map.put(result, :already_open, already_open)
      json(conn, result)
    end
  end
end
