defmodule GingkoWeb.Api.HealthController do
  @moduledoc false

  use GingkoWeb, :controller

  def show(conn, _params) do
    version = Application.spec(:gingko, :vsn) |> to_string()

    conn
    |> put_status(:ok)
    |> json(%{status: "ok", version: version})
  end
end
