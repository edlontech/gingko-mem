defmodule GingkoWeb.PageController do
  use GingkoWeb, :controller

  def home(conn, _params) do
    settings = Gingko.Settings.load(settings_opts())

    if settings.ready? do
      redirect(conn, to: ~p"/projects")
    else
      conn
      |> put_flash(:info, "Setup required before Gingko can use your configured providers.")
      |> redirect(to: ~p"/setup")
    end
  end

  defp settings_opts do
    Application.get_env(:gingko, :settings_opts, [])
  end
end
