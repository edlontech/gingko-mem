# Deployment

Gingko ships three ways:

1. Run `mix phx.server` from source (dev, short-lived servers).
2. Build a Mix release for a target host.
3. Package as a Burrito single-file binary for distribution.

## From source

Fine for development. Requires Elixir, Erlang, and a JS toolchain on the host.

```bash
mix setup
mix phx.server
```

Run migrations explicitly if needed:

```bash
mix ecto.migrate
```

## Mix release

Standard Elixir release. Suitable for long-running servers where you control
the host.

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/gingko/bin/gingko start
```

Release hook: the release step runs migrations on boot — see `Gingko.Release`.

## Burrito binary

Gingko's release is Burrito-wrapped, producing a single executable per target:

| Target          | Triple          |
|-----------------|-----------------|
| `macos_silicon` | darwin / arm64  |
| `linux`         | linux / x86_64  |
| `linux_arm`     | linux / aarch64 |

Build:

```bash
MIX_ENV=prod mix release
# Artifacts land in burrito_out/
```

On first launch the binary unpacks itself into a user-local cache and boots.
Subsequent launches skip the unpack.

## Configuration at runtime

All runtime configuration comes from `$GINGKO_HOME/config.toml` and environment
variables — there is no compiled-in config for LLM keys, ports, or memory
paths. Set:

| Variable                 | Purpose                                            |
|--------------------------|----------------------------------------------------|
| `GINGKO_HOME`            | Override the default `~/.gingko` application home. |
| `ANTHROPIC_API_KEY` etc. | Whatever env-var names your `[llm]` and `[embeddings]` providers require. |

For a headless server, pre-seed `config.toml` before first boot so the setup
redirect never fires.

## Reverse proxies

The MCP endpoint uses streamable HTTP. Any reverse proxy that handles HTTP/1.1
keep-alive and chunked responses works; for nginx you want `proxy_buffering
off;` on the `/mcp` location so events are not held.

## Persistence and backups

All state lives under `$GINGKO_HOME`:

- `memory/` — Mnemosyne DETS graph files.
- `metadata.sqlite3` — projects, sessions, summaries.
- `config.toml` — runtime configuration.

A straight directory copy is a valid backup. For a hot backup, shut the server
down briefly so DETS files flush, or snapshot the volume.

## Health and supervision

The Phoenix application tree supervises:

- The Mnemosyne runtime and its project repos.
- `Gingko.Embeddings.BumblebeeServing` (lazy; only runs when bumblebee is
  selected).
- `Oban` for background work (summary workers use it).
- LiveView-backed monitoring components.

If one of these crashes the supervisor restarts it — there is no need for a
watchdog outside the BEAM. For host-level supervision use systemd, launchd, or
whatever you already run.

## Scaling notes

- Gingko is single-node. It stores graphs in DETS files local to the host; it
  is not designed for horizontal scale-out.
- The bottleneck under load is usually the LLM provider, not Gingko itself.
  Use `[overrides]` to route expensive pipeline steps (e.g. `reason_semantic`)
  to a cheaper model.
- For local embeddings under high throughput, prefer running on Linux with
  EXLA so the serving pool saturates CPU/GPU; macOS with EMLX works for
  development but is single-accelerator.
