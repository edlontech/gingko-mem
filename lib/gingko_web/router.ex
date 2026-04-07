defmodule GingkoWeb.Router do
  use GingkoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GingkoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GingkoWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/setup", SetupLive
    live "/projects", ProjectsLive
    live "/projects/:project_id", ProjectLive
    live "/projects/:project_id/:tab", ProjectLive
  end

  scope "/" do
    forward "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug, server: Gingko.MCP.Server
  end

  scope "/api", GingkoWeb.Api do
    pipe_through :api

    get "/projects", ProjectController, :index
    post "/projects/:project_id/open", ProjectController, :open

    post "/projects/:project_id/sessions", SessionController, :create
    get "/sessions/:session_id/state", SessionController, :show
    post "/sessions/:session_id/commit", SessionController, :commit
    post "/sessions/:session_id/commit_and_continue", SessionController, :commit_and_continue

    post "/sessions/:session_id/steps", StepController, :create
    post "/sessions/:session_id/summarize", SummarizeController, :create

    get "/projects/:project_id/recall", RecallController, :show
    get "/projects/:project_id/latest", LatestMemoriesController, :index
    get "/projects/:project_id/nodes/:node_id", NodeController, :show
    post "/projects/:project_id/maintenance", MaintenanceController, :create

    get "/projects/:project_id/session_primer", SessionPrimerController, :show
    get "/projects/:project_id/clusters/:slug", ClusterController, :show
    post "/projects/:project_id/summaries/refresh", RefreshPrincipalMemoryController, :create
    get "/summaries/status", SummariesStatusController, :show
    put "/projects/:project_id/charter", CharterController, :update
  end

  if Application.compile_env(:gingko, :dev_routes) do
    import Phoenix.LiveDashboard.Router
    import Oban.Web.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: GingkoWeb.Telemetry
      oban_dashboard("/oban")
    end
  end
end
