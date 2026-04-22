defmodule GingkoWeb.Api.SessionController do
  @moduledoc false

  use GingkoWeb, :controller

  action_fallback GingkoWeb.Api.FallbackController

  def create(conn, %{"project_id" => project_id, "goal" => goal} = params) do
    attrs = %{
      project_id: project_id,
      goal: goal,
      agent: params["agent"],
      thread_id: params["thread_id"]
    }

    with {:ok, result} <- Gingko.Memory.start_session(attrs) do
      conn |> put_status(:created) |> json(result)
    end
  end

  def create(_conn, %{"project_id" => _}) do
    {:error, %{code: :invalid_params, message: "goal is required"}}
  end

  def show(conn, %{"session_id" => session_id}) do
    with {:ok, result} <- Gingko.Memory.session_state(session_id) do
      json(conn, result)
    end
  end

  def commit(conn, %{"session_id" => session_id}) do
    with {:ok, result} <- Gingko.Memory.close_async(%{session_id: session_id}) do
      json(conn, result)
    end
  end

  def commit_and_continue(
        conn,
        %{"session_id" => session_id, "project_id" => project_id, "goal" => goal} = params
      ) do
    attrs = %{
      session_id: session_id,
      project_id: project_id,
      goal: goal,
      agent: params["agent"],
      thread_id: params["thread_id"]
    }

    with {:ok, result} <- Gingko.Memory.commit_session(attrs) do
      conn |> put_status(:created) |> json(result)
    end
  end

  def commit_and_continue(_conn, %{"session_id" => _}) do
    {:error, %{code: :invalid_params, message: "project_id and goal are required"}}
  end
end
