# Memory Model

Gingko stores agent memory as a graph per project. This guide explains the
concepts an integrator or operator needs to reason about what ends up in the
graph and how it is retrieved.

## Three layers of state

```
project  ──>  sessions  ──>  steps  ──>  graph nodes + edges
```

- **Project** — a namespace with its own memory graph and SQLite metadata.
  One project = one Mnemosyne repo = one DETS file on disk. Created on the
  first `open_project_memory` call.
- **Session** — a goal-scoped unit of work within a project. Sessions bundle
  steps and carry them across commit. Metadata lives in SQLite.
- **Step** — a single `(observation, action)` pair. Steps are the atomic
  input; Gingko's extractor decides what nodes and edges they produce.
- **Graph** — the durable product. Nodes have types, embeddings, and typed
  links. Stored via Mnemosyne (`mnemosyne`) in DETS.

Project metadata (project rows, session rows, derived summaries) lives in
SQLite at `$GINGKO_HOME/metadata.sqlite3`. Memory *graphs* live at
`$GINGKO_HOME/memory/<project>/...`.

## Node types

Gingko/Mnemosyne distinguishes several node kinds. You configure retrieval
parameters per type in `config.toml` under `[value_function.params]`.

| Type         | What it represents                                              |
|--------------|-----------------------------------------------------------------|
| `semantic`   | Stable, deduplicated facts. The long-term knowledge layer.      |
| `episodic`   | Raw session steps with timestamps. The narrative layer.         |
| `procedural` | How-to patterns and repeatable recipes.                         |
| `subgoal`    | Intermediate goals inferred mid-session.                        |
| `tag`        | Topic nodes that cluster related memories via `:membership`.    |
| `source`     | External provenance anchors (URLs, file paths).                 |
| `intent`     | The user-facing goal behind the session.                        |

Nodes carry embeddings so recall can do semantic nearest-neighbour search. Tags
are the backbone of the summary layer: when a cluster is summarized, it is a
summary of the semantic/episodic nodes pointing at a tag.

## The write path

The explicit write flow is:

1. `open_project_memory` — idempotent, opens (or reopens) the repo.
2. `start_session` — returns a `session_id`.
3. `append_step` — one call per observation/action pair.
4. End of session — Gingko auto-commits.

Call `close_async` only when you explicitly want to flush the session mid-flow
(for example before a long-running operation). Call `commit_session` when you
want to commit *and* continue with a fresh session under the same goal.

On commit, Mnemosyne runs the extraction pipeline against the accumulated
steps. The pipeline is broken into named stages (e.g. `extract`, `merge_intent`,
`reason_semantic`, `get_state`) — you can target individual stages with LLM
overrides. See [Configuration](configuration.md#overrides).

## The read path

### `recall`

The primary retrieval tool. Runs semantic similarity against the project's
graph using the value function configured for each node type. Optionally scope
to a single `session_id` to keep results within one narrative arc.

### `get_node`

Given a `node_id` from a prior recall, fetch the node plus its metadata and
immediate linked nodes. Use this to traverse the graph or inspect a specific
memory.

### `latest_memories`

Tail of the most recently written semantic/episodic nodes. Useful when you
want "what just happened" context that the summary layer has not yet
absorbed. Accepts a `format: "markdown"` option for human-readable output.

### `get_session_primer`

The composed priming document for a project. Contains:

- the built-in recall playbook,
- the optional project charter,
- the latest project-state summary,
- the cluster index,
- and a configurable tail of recent memories.

Load this at session start to give the agent context without burning tokens on
individual recalls. See [Summaries & Session Primer](summaries-and-primer.md).

## Lifecycle states

Session state (available via `get_session_state`) follows a simple lifecycle:

- `collecting` — accepting steps.
- `closing` — a close was queued and extraction is running asynchronously.
- finished — session row is marked done in SQLite.

Auto-commit behaviour, flush timeouts, and idle session timeouts are all
configurable in the `[mnemosyne]` section of `config.toml`.

## Where data actually lives

| File / dir                                | Role                                    |
|-------------------------------------------|-----------------------------------------|
| `$GINGKO_HOME/config.toml`                | Runtime configuration.                  |
| `$GINGKO_HOME/memory/<project>/*.dets`    | Mnemosyne graph files (per project).    |
| `$GINGKO_HOME/metadata.sqlite3`           | Projects, sessions, summaries, deltas.  |

Back up the whole `$GINGKO_HOME` to back up a Gingko install. Restoring is a
directory copy.
