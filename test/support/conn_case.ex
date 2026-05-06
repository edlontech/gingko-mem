defmodule GingkoWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and import other
  functionality to make it easier to build common request data.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint GingkoWeb.Endpoint

      use GingkoWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import GingkoWeb.ConnCase
    end
  end

  setup do
    Gingko.Repo.query!("DELETE FROM provider_credentials")
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
