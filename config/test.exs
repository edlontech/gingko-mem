import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :gingko, GingkoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "aMNQjmID8QreNiv/jO2omR5fhCsoWz9/ASRyeuTqiP7J83tioIIU6NioNZ+BoBJe",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :gingko, Gingko.Memory,
  storage_root: System.tmp_dir!(),
  mnemosyne_config: %{
    llm: %{model: "mock-llm", opts: %{}},
    embedding: %{model: "mock-embedding", opts: %{}}
  },
  llm_adapter: Gingko.TestSupport.Mnemosyne.MockLLM,
  embedding_adapter: Gingko.TestSupport.Mnemosyne.MockEmbedding

config :gingko, Gingko.Repo,
  database: Path.expand("../tmp/gingko_test.sqlite3", __DIR__),
  pool_size: 1

config :gingko, Oban, testing: :manual

config :gingko, Gingko.UpdateChecker, enabled: false

config :gingko, Gingko.Cost.Config, enabled: false
