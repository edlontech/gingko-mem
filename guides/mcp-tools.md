# MCP Tools

The Gingko MCP server is named `gingko` and advertises the `tools` capability
over streamable HTTP at `/mcp`. Every tool returns either a structured result
or a `{code, message}` error map; codes are stable across versions.

## Write flow

### `open_project_memory`

Initialize or reconnect to a project's memory graph. Must be called before any
other memory operation for that project. Idempotent.

| Field        | Type    | Required | Notes                                          |
|--------------|---------|----------|------------------------------------------------|
| `project_id` | string  | yes      | Usually the project folder name.               |

### `start_session`

Begin a new memory session within a project.

| Field        | Type   | Required | Notes                                              |
|--------------|--------|----------|----------------------------------------------------|
| `project_id` | string | yes      | Must have been opened.                             |
| `goal`       | string | yes      | Concise goal; used for retrieval and grouping.     |
| `agent`      | string | no       | Identifier for the agent, for multi-agent setups.  |
| `thread_id`  | string | no       | External conversation/thread correlation.          |

### `append_step`

Record one observation/action pair against the active session.

| Field         | Type   | Required | Notes                                           |
|---------------|--------|----------|-------------------------------------------------|
| `session_id`  | string | yes      |                                                 |
| `observation` | string | yes      | Context, findings, or current state.            |
| `action`      | string | yes      | Decision made, code written, conclusion.        |

### `close_async`

Close and asynchronously commit a session. You normally do **not** need to call
this — sessions auto-commit when they end. Use it only to force an early
flush, for example before a long-running operation.

| Field        | Type   | Required |
|--------------|--------|----------|
| `session_id` | string | yes      |

### `commit_session`

Commit the current session *and* start a new one for the same project. The new
session inherits `agent` and `thread_id` if provided and continues with the
same or an updated goal.

| Field        | Type   | Required | Notes                                   |
|--------------|--------|----------|-----------------------------------------|
| `session_id` | string | yes      | Current session.                        |
| `project_id` | string | yes      |                                         |
| `goal`       | string | yes      | Goal for the new session.               |
| `agent`      | string | no       |                                         |
| `thread_id`  | string | no       |                                         |

## Read flow

### `recall`

Semantic similarity search across the project graph.

| Field        | Type   | Required | Notes                                        |
|--------------|--------|----------|----------------------------------------------|
| `project_id` | string | yes      |                                              |
| `query`      | string | yes      | Natural language query.                      |
| `session_id` | string | no       | Optional scope to a single session's context.|

### `get_node`

Fetch a single node plus metadata and immediate neighbours.

| Field        | Type   | Required | Notes                                |
|--------------|--------|----------|--------------------------------------|
| `project_id` | string | yes      |                                      |
| `node_id`    | string | yes      | UUID from a prior recall or get_node.|

### `latest_memories`

The most recently created memories, newest first.

| Field        | Type             | Required | Notes                                        |
|--------------|------------------|----------|----------------------------------------------|
| `project_id` | string           | yes      |                                              |
| `top_k`      | integer          | no       | Defaults to 10.                              |
| `types`      | array of string  | no       | Defaults to `["semantic", "episodic"]`.      |
| `format`     | string           | no       | `"json"` (default) or `"markdown"`.          |

### `get_session_state`

Look up the lifecycle state of a session.

| Field        | Type   | Required |
|--------------|--------|----------|
| `session_id` | string | yes      |

### `list_projects`

Return every project registered in Gingko along with display names and whether
it has custom extraction overlays.

No parameters.

## Summary layer

These tools are available whenever `[summaries].enabled = true`. See
[Summaries & Session Primer](summaries-and-primer.md).

### `get_session_primer`

Composed priming document: playbook + optional charter + project state + cluster
index + recent memories. Load at session start or to re-orient mid-session.

| Field          | Type    | Required | Notes                                              |
|----------------|---------|----------|----------------------------------------------------|
| `project_id`   | string  | yes      |                                                    |
| `recent_count` | integer | no       | Size of the recent-memories tail.                  |

### `get_cluster`

Fetch one cluster summary.

| Field         | Type   | Required | Notes                                             |
|---------------|--------|----------|---------------------------------------------------|
| `project_id`  | string | yes      |                                                   |
| `slug`        | string | no       | Human-readable id shown in the primer index.      |
| `tag_node_id` | string | no       | Alternative UUID-based lookup.                    |

One of `slug` or `tag_node_id` is required.

### `refresh_principal_memory`

Force regeneration of summary artifacts, bypassing the debounce and dirty-
tracker thresholds.

| Field          | Type   | Required | Notes                                     |
|----------------|--------|----------|-------------------------------------------|
| `project_id`   | string | yes      |                                           |
| `scope`        | string | no       | `"all"` (default), `"state"`, `"cluster"`.|
| `cluster_slug` | string | no       | Required when `scope = "cluster"`.        |

### `set_charter`

Upsert the project charter — the human-authored North Star that primes every
session alongside the LLM-generated state summary.

| Field        | Type   | Required | Notes                                             |
|--------------|--------|----------|---------------------------------------------------|
| `project_id` | string | yes      |                                                   |
| `content`    | string | yes      | Markdown; non-empty.                              |

Returns `charter_locked` if the stored charter is locked; unlock it from the
database if you need to overwrite.

## Maintenance

### `run_maintenance`

Kick off an asynchronous maintenance operation. See
[Maintenance & Tuning](maintenance-and-tuning.md).

| Field        | Type   | Required | Notes                                              |
|--------------|--------|----------|----------------------------------------------------|
| `project_id` | string | yes      |                                                    |
| `operation`  | string | yes      | `"decay"`, `"consolidate"`, or `"validate"`.       |

## Common error codes

| Code                        | Meaning                                                  |
|-----------------------------|----------------------------------------------------------|
| `project_not_open`          | Call `open_project_memory` first.                        |
| `session_not_found`         | Session id was never created or has been purged.         |
| `invalid_session_state`     | Session is not in a state that accepts this operation.   |
| `invalid_params`            | Required field missing or malformed.                     |
| `invalid_operation`         | Unknown `run_maintenance` operation.                     |
| `cluster_not_found`         | No cluster summary for the given slug/tag.               |
| `charter_locked`            | Charter is locked; cannot overwrite via MCP.             |
| `memory_operation_failed`   | Generic fallthrough; see `message`.                      |
