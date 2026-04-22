# Gingko Guides

Long-form documentation for running, customizing, and integrating Gingko.

## Start here

- [Getting Started](getting-started.md) — install, first run, hooking an MCP client.
- [Memory Model](memory-model.md) — projects, sessions, steps, and how the graph is built.
- [MCP Tools](mcp-tools.md) — reference for every tool the server exposes.

## Customization

- [Configuration](configuration.md) — everything in `config.toml`.
- [Extraction Profiles](extraction-profiles.md) — domain-specific extraction presets and per-project overlays.
- [Summaries & Session Primer](summaries-and-primer.md) — charter, state, clusters, and the session primer document.
- [Maintenance & Tuning](maintenance-and-tuning.md) — decay, consolidation, validation, and value-function parameters.

## Operations

- [Deployment](deployment.md) — running Gingko via `mix`, releases, and Burrito binaries.

## Where things live

- Source of truth for code: `lib/gingko/`.
- Runtime state: `$GINGKO_HOME` (default `~/.gingko`), containing `config.toml`, `memory/` DETS files, and `metadata.sqlite3`.
- Web UI: `http://localhost:4000` in dev; `/setup` for configuration, `/projects` for the monitor.
