import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/gingko start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if config_env() != :test do
  config :gingko, GingkoWeb.Endpoint, server: true

  settings = Gingko.Settings.load()
  memory_runtime = Gingko.Settings.mnemosyne_runtime(settings)

  endpoint_port =
    String.to_integer(System.get_env("GINGKO_PORT", Integer.to_string(settings.server.port)))

  config :gingko, GingkoWeb.Endpoint, http: [port: endpoint_port]

  logs_dir = Path.join(settings.home, "logs")
  File.mkdir_p!(logs_dir)

  config :gingko, :log_file, Path.join(logs_dir, "gingko.log")

  config :gingko, :settings, settings

  config :gingko, Gingko.Memory,
    storage_root: memory_runtime.storage_root,
    mnemosyne_config: memory_runtime.mnemosyne_config,
    llm_adapter: memory_runtime.llm_adapter,
    embedding_adapter: memory_runtime.embedding_adapter

  config :gingko, Gingko.Summaries.Config, Gingko.Settings.summaries_env(settings)

  config :gingko, Gingko.Repo, database: Gingko.Settings.metadata_db_path(settings)
end

if config_env() == :prod do
  secret_key_base = Gingko.Release.ensure_secret_key_base!()

  config :gingko, GingkoWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}],
    secret_key_base: secret_key_base
end
