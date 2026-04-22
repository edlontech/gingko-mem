defmodule GingkoWeb.Api.RecallController do
  @moduledoc false

  use GingkoWeb, :controller

  action_fallback GingkoWeb.Api.FallbackController

  def show(conn, %{"project_id" => project_id, "query" => query} = params) do
    attrs = %{
      project_id: project_id,
      query: query,
      session_id: params["session_id"]
    }

    with {:ok, result} <- Gingko.Memory.recall(attrs) do
      json(conn, result)
    end
  end

  def show(_conn, %{"project_id" => _}) do
    {:error, %{code: :invalid_params, message: "query is required"}}
  end
end
