# Getting Started

Gingko is a standalone Phoenix server that exposes a project-scoped memory graph
over MCP. Any agent that speaks MCP can open a project, record observations, and
recall memories from past sessions.

## Requirements

- Elixir `~> 1.15` and Erlang/OTP.
- Yarn 1.x, or Node with Corepack enabled, for frontend assets.
- A macOS or Linux host. On macOS Gingko uses EMLX; on Linux it uses EXLA.

## Install and boot

```bash
mix setup        # deps + frontend assets
mix phx.server
```

The HTTP endpoint comes up on `http://localhost:4000`:

- `/` — project grid and quick links.
- `/setup` — configuration UI, forced on first boot when config is missing.
- `/projects` — live monitor with graph visualization.
- `/mcp` — the MCP streamable-HTTP endpoint that clients connect to.

On first launch Gingko creates `$GINGKO_HOME` (default `~/.gingko`) containing a
default `config.toml` and an empty `memory/` directory. No API keys are written
to disk — only the env-var *names* Gingko should read at runtime.

## First project

From an MCP-enabled client, open the project and start a session:

```
open_project_memory project_id="my-app"
start_session       project_id="my-app" goal="investigate auth redirects"
append_step         session_id=<id>
                    observation="login redirects loop when session cookie is missing"
                    action="added cookie check in LoginController.show"
```

Sessions auto-commit when they end, so you don't normally need to call
`close_async`. To recall what you've learned later:

```
recall project_id="my-app" query="login redirect loop"
```

See [MCP Tools](mcp-tools.md) for the full tool reference.

## Pointing an MCP client at Gingko

Any MCP client that supports streamable HTTP can connect to
`http://localhost:4000/mcp`. The server name is `gingko` (version `0.1.0`) and
advertises the `tools` capability.

If your client needs a stdio bridge, wrap the HTTP endpoint with a standard MCP
HTTP-to-stdio adapter — Gingko itself does not ship a stdio transport.

## Missing configuration

If Gingko is missing required configuration it still boots but redirects `/`
to `/setup`. Fill in the form and save — the server rewrites `config.toml`.
Restart if you change embedding or LLM providers so adapters rebuild.

Secrets (API keys) are read only from environment variables named in
`config.toml`. Set them in your shell or process manager:

```bash
export ANTHROPIC_API_KEY=sk-...
export OPENAI_API_KEY=sk-...
```

## Next

- [Memory Model](memory-model.md) — understand what gets stored and why.
- [Configuration](configuration.md) — tune Gingko to your workload.
