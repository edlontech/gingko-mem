# Gingko Memory for Claude Code

Graph-based persistent memory for Claude Code via the Gingko MCP server.

## Install

```
/plugin marketplace add edlontech/gingko
/plugin install gingko-memory@gingko
```

On the next session start, the plugin will:

1. Download the matching gingko binary from the GitHub release to `~/.gingko/bin/gingko` (one-time, ~50MB).
2. Verify its SHA256 against the published `SHA256SUMS`.
3. Register a launchd (macOS) or systemd user unit (Linux) via `gingko service install`.
4. Start the service and wait for `http://127.0.0.1:8008/health`.
5. Connect Claude Code to the MCP at `http://127.0.0.1:8008/mcp`.

## Configuration

Gingko reads `~/.gingko/config.toml`. Change the default port there; if you do, also edit the `url` in `~/.claude.json` under `mcpServers.gingko` so Claude Code points at the right endpoint.

Override the discovery URL used by the session hooks:

```
export GINGKO_URL=http://127.0.0.1:9000
```

## Supported platforms

- macOS (Apple Silicon)
- Linux (x86_64, aarch64)

## Troubleshooting

**Service dies on logout (Linux)** — enable user-service lingering:

```
sudo loginctl enable-linger $USER
```

**Bootstrap failed** — run manually:

```
~/.gingko/bin/gingko service install
~/.gingko/bin/gingko service start
~/.gingko/bin/gingko status
```

**Force reinstall** — delete the marker:

```
rm ~/.gingko/.install-version
```
