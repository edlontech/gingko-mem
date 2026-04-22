# Gingko

Gingko is a application that exposes a project-scoped memory graph
over [MCP](https://modelcontextprotocol.io). Any agent that speaks MCP can
open a project, record observations, recall past memories, and navigate the
knowledge graph that builds up across sessions.

Under the hood it uses [Mnemosyne](https://github.com/edlontech/mnemosyne) as a memory engine

## Quick start

```bash
mix setup         # fetch deps, install assets
mix phx.server
```

Then point an MCP client at `http://localhost:4000/mcp`. The first time the
server boots it creates `~/.gingko/` with a default config and guides you
through setup at `http://localhost:4000/setup` if anything is missing.

## Documentation

Long-form guides live in [`guides/`](guides/README.md):

- [Getting Started](guides/getting-started.md)
- [Memory Model](guides/memory-model.md) — projects, sessions, steps, node types
- [MCP Tools Reference](guides/mcp-tools.md)
- [Configuration](guides/configuration.md) — every knob in `config.toml`
- [Extraction Profiles](guides/extraction-profiles.md) — per-domain and per-project overlays
- [Summaries & Session Primer](guides/summaries-and-primer.md) — charter, state, clusters
- [Maintenance & Tuning](guides/maintenance-and-tuning.md) — decay, consolidate, validate, value function
- [Deployment](guides/deployment.md) — releases and Burrito binaries

## MCP tool surface

Write flow:

- `open_project_memory` → `start_session` → `append_step` → (auto-commit on
  session end; `close_async` or `commit_session` for explicit flushes)

Read flow:

- `recall`, `get_node`, `get_session_state`, `list_projects`, `latest_memories`

Summary layer (opt-in via `[summaries].enabled`):

- `get_session_primer`, `get_cluster`, `set_charter`, `refresh_principal_memory`

Graph maintenance:

- `run_maintenance` with `decay`, `consolidate`, or `validate`

See [MCP Tools](guides/mcp-tools.md) for the full reference.

## Runtime layout

All state lives under `$GINGKO_HOME` (default `~/.gingko`):

```
~/.gingko/
├── config.toml          # runtime configuration
├── memory/              # Mnemosyne DETS graph files, one subdir per project
└── metadata.sqlite3     # projects, sessions, summaries
```

API keys are never written to `config.toml` — only the env-var names to read.
Export `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or whichever provider keys your
configured providers need.

## Local development

Asset toolchain requirement: Yarn 1.x, or Node with Corepack enabled.
`mix setup` auto-detects `yarn`, then `corepack yarn`, and exits with a clear
message if neither is available.

```bash
mix setup
mix phx.server          # http://localhost:4000
```

The web UI has three main views:

- `/` — project grid with live stats.
- `/setup` — edit `config.toml` from the browser.
- `/projects` — real-time graph monitor backed by Cytoscape.

## Testing

```bash
mix test                 # full suite
mix precommit            # warnings-as-errors + deps.unlock --unused + format + test
```

Integration coverage for the MCP tools lives in
`test/gingko/mcp/write_flow_test.exs` and `test/gingko/mcp/read_flow_test.exs`.
