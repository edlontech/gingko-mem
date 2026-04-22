defmodule GingkoWeb.Api.SummarizeController do
  @moduledoc false

  use GingkoWeb, :controller

  action_fallback GingkoWeb.Api.FallbackController

  def create(conn, %{"session_id" => session_id, "content" => content}) do
    with {:ok, extracted} <-
           Gingko.Memory.summarize_step(%{session_id: session_id, content: content}) do
      conn |> put_status(:accepted) |> json(extracted)
    end
  end

  def create(_conn, %{"session_id" => _}) do
    {:error, %{code: :invalid_params, message: "content required"}}
  end
end
