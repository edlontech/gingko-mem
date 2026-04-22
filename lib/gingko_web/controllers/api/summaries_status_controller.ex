defmodule GingkoWeb.Api.SummariesStatusController do
  @moduledoc false

  use GingkoWeb, :controller

  alias Gingko.Summaries.Config

  def show(conn, _params) do
    if Config.enabled?() do
      json(conn, %{enabled: true})
    else
      conn |> put_status(:service_unavailable) |> json(%{enabled: false})
    end
  end
end
