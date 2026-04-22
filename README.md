# Gingko

Gingko is a Phoenix application that exposes project-scoped memory over MCP.
It uses `mnemosyne` as the memory engine and keeps the public contract narrow:
agents open a project repo, write sessions into it, and can now recall and
inspect memory through MCP tools.

## Runtime Configuration

Gingko now uses an application home instead of expecting end users to edit
Elixir config files.

- Default app home: `~/.gingko`
- Override app home: `GINGKO_HOME=/custom/path`
- Non-secret settings: `GINGKO_HOME/config.toml`
- Memory storage: `GINGKO_HOME/memory/`
- Secrets: environment variables only

On first boot, Gingko creates the app home, a default `config.toml`, and the
memory directory automatically.

### Setup Flow

If Gingko is missing required configuration, visiting `/` redirects to
`/setup`.

The setup page lets you edit:

- memory path
- LLM provider, model, and API key env-var name
- embedding provider and model
- embedding API key env-var name for remote providers
- server host and port

Gingko stores only env-var names in `config.toml`. It does not write API keys
to disk. If you choose the local `bumblebee` embedding provider, Gingko starts
the embedding model itself and defaults to `intfloat/e5-base-v2`.

### Example `config.toml`

```toml
[paths]
memory = "memory"

[llm]
provider = "anthropic"
model = "claude-sonnet-4"
api_key_env = "ANTHROPIC_API_KEY"

[embeddings]
provider = "bumblebee"
model = "intfloat/e5-base-v2"
api_key_env = ""

[server]
host = "127.0.0.1"
port = 4000
```

## Current MCP Tool Surface

Write tools:

- `open_project_memory`
- `start_session`
- `append_step`
- `close_and_commit`

Read tools:

- `recall`
- `get_node`
- `get_session_state`
- `list_projects`

## Workflow

The write path is explicit:

1. Call `open_project_memory` with a `project_id`
2. Call `start_session`
3. Call `append_step` one or more times
4. Call `close_and_commit`

Once a project has memory, clients can use:

- `recall` to retrieve project memory for a query
- `get_node` to inspect a specific node plus metadata and linked nodes
- `get_session_state` to inspect a session lifecycle state
- `list_projects` to see currently open Gingko-managed repos

## Local Development

Install dependencies and assets:

- Frontend package manager requirement: Yarn 1.x, or Node with Corepack enabled.
- `mix setup` auto-detects in this order: `yarn`, then `corepack yarn`.
- If neither is available, `mix setup` exits with a clear message.

```bash
mix setup
```

Start the server:

```bash
mix phx.server
```

The Phoenix endpoint runs on [http://localhost:4000](http://localhost:4000) and
the MCP endpoint is available at [http://localhost:4000/mcp](http://localhost:4000/mcp).

If `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or any custom env var referenced in
`config.toml` is missing, Gingko still boots and guides you through setup in
the browser.

## Testing

Run the full test suite:

```bash
mix test
```

Run the MCP integration coverage directly:

```bash
mix test test/gingko/mcp/write_flow_test.exs test/gingko/mcp/read_flow_test.exs
```
