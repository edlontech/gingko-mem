# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :gingko,
  generators: [timestamp_type: :utc_datetime],
  ecto_repos: [Gingko.Repo]

config :anubis_mcp, log: false, session_store: [enabled: false]

# Runtime settings should provide end-user memory configuration.
# These values are compile/runtime-safe fallbacks until runtime.exs loads.
config :gingko, Gingko.Memory,
  storage_root: Path.expand("~/.gingko/memory"),
  mnemosyne_config: %{
    llm: %{model: "openai:gpt-4o-mini", opts: %{}},
    embedding: %{model: "openai:text-embedding-3-small", opts: %{}}
  },
  llm_adapter: Mnemosyne.Adapters.SycophantLLM,
  embedding_adapter: Mnemosyne.Adapters.SycophantEmbedding

config :gingko, Gingko.Repo,
  journal_mode: :wal,
  pool_size: 5

config :gingko, Gingko.Cost.Config,
  enabled: true,
  retention_days: 0,
  batch_size_max: 50,
  flush_interval_ms: 500

config :gingko, Oban,
  engine: Oban.Engines.Lite,
  repo: Gingko.Repo,
  queues: [summaries: 2, maintenance: 1],
  notifier: Oban.Notifiers.PG,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Gingko.Cost.Pruner}
     ]}
  ]

# Configure the endpoint
config :gingko, GingkoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GingkoWeb.ErrorHTML, json: GingkoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Gingko.PubSub,
  live_view: [signing_salt: "Wp1eBjaA"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  gingko: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  gingko: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, level: :info

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
