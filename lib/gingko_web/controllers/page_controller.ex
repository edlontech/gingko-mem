defmodule GingkoWeb.PageController do
  use GingkoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
