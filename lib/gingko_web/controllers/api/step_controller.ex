defmodule GingkoWeb.Api.StepController do
  @moduledoc false

  use GingkoWeb, :controller

  action_fallback GingkoWeb.Api.FallbackController

  def create(conn, %{"session_id" => session_id, "observation" => observation, "action" => action}) do
    attrs = %{session_id: session_id, observation: observation, action: action}

    with {:ok, result} <- Gingko.Memory.append_step(attrs) do
      conn |> put_status(:accepted) |> json(result)
    end
  end

  def create(_conn, %{"session_id" => _} = params) do
    missing =
      ["observation", "action"]
      |> Enum.reject(&Map.has_key?(params, &1))
      |> Enum.join(", ")

    {:error, %{code: :invalid_params, message: "#{missing} required"}}
  end
end
