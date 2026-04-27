---
name: memory
description: Use whenever working in a Gingko-enabled project (SessionStart hook prints "[gingko] primed session context" or "[gingko] Loaded N recent memories"). Teaches how to recall past context, record observation/action steps, traverse the knowledge graph, and choose between the gingko MCP tools and the gingko.sh CLI helper. Triggers on "what did we decide", "have I seen this before", "remember that", "record this", "save to memory", or any non-trivial task in a Gingko project.
---

# Gingko Memory Integration

Gingko is a graph-based memory engine that persists what you observe and do across sessions. Past sessions become a queryable knowledge graph: semantic nodes (facts, decisions, patterns), episodic nodes (raw observation/action pairs), and tag clusters that group related work. Future-you can recall any of it.

## The Two Interfaces

You have two ways to talk to Gingko. They reach the same backend, but differ in ergonomics:

| Need | Prefer |
|---|---|
| Record a step, recall by query, look up a node | **MCP tools** (`mcp__plugin_gingko_gingko__*`) — typed args, structured results, no shell escaping |
| Quick one-shot from a script or when you don't know `project_id` / `session_id` | **`gingko.sh` CLI** (`$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh <subcommand>`) — auto-detects project from git remote and reads the active session file |

Use the MCP tools by default. Reach for `gingko.sh` only when you need to bootstrap (discover IDs) or when you're already in a shell pipeline.

### Discovering IDs for MCP calls

MCP tools require `project_id` (and `session_id` for `append_step`). Get them once per turn and reuse:

```bash
$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh project-id   # prints e.g. "github.com/edlontech/gingko"
$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh session-id   # prints the active session UUID, empty if none
```

If `session-id` is empty the SessionStart hook either failed or the service was unreachable — fall back to the CLI (`gingko.sh append-step ...`), which is a no-op when there's no session, instead of trying to call `start_session` yourself. The hooks own the lifecycle.

## Session Lifecycle (Already Handled)

The plugin's `SessionStart` hook already calls `open_project_memory` + `start_session` and primes the conversation with either a session primer or the latest 100 memories. The `Stop` hook summarizes the transcript and commits steps. **Do not** call `open_project_memory`, `start_session`, `commit_session`, or `close_async` in normal flow — those are reserved for explicit mid-workflow flushes (e.g. before a multi-hour operation, or after a hard context switch within the same session).

If `commit_session` is genuinely needed, it returns a fresh `session_id` to keep using; replace your cached one.

## Recall: Read Before You Write

Before doing meaningful work, check whether past sessions already contain relevant context. Recall is cheap; rediscovering things is not.

```
mcp__plugin_gingko_gingko__recall
  project_id: "<from project-id>"
  query: "auth middleware token refresh"   # natural language, be specific
  session_id: optional, scopes to one session
```

When to recall:
- Starting work on a module/feature you suspect was touched before.
- The user describes a symptom that sounds familiar ("again", "still", "back to").
- About to make an architectural decision — check whether one was already made.
- Investigating a bug that may have been seen before.

What you get back: a list of memories with `content`, `node_id`, `node_type` (`semantic` / `episodic`), and provenance. Use the `node_id` to drill in.

### Drilling deeper

```
mcp__plugin_gingko_gingko__get_node
  project_id: "<id>"
  node_id: "<from a recall result>"
```

Returns the node plus its graph neighbors (linked memories). Follow neighbor `node_id`s to traverse — this is how you reconstruct the *why* behind a decision, not just the *what*.

### When recall has no specific query

```
mcp__plugin_gingko_gingko__latest_memories
  project_id: "<id>"
  top_k: 20            # default 10
  format: "markdown"   # or "json" (default)
  types: ["semantic", "episodic"]   # filter; default is both
```

Use this to skim what was learned recently when you don't know what you're looking for yet — e.g. when you re-enter a project after time away and the primer wasn't loaded.

### Re-priming mid-session

If the conversation has drifted far from the original context, fetch the primer again:

```
mcp__plugin_gingko_gingko__get_session_primer
  project_id: "<id>"
  recent_count: 20   # optional
```

The primer composes: recall playbook + charter (if set) + project state summary + cluster index + recent memory tail. Treat the cluster index as a table of contents — each entry has a `slug` you can pass to `get_cluster`.

```
mcp__plugin_gingko_gingko__get_cluster
  project_id: "<id>"
  slug: "auth-middleware"   # from the cluster index
```

Clusters are the curated, headline-level view; recall is the granular search. Use clusters when you want the canonical summary of a topic, recall when you want raw evidence.

## Append: Record What Matters

```
mcp__plugin_gingko_gingko__append_step
  session_id: "<from session-id>"
  observation: "what you discovered, including specifics"
  action: "what you did and why"
```

Or shell-equivalent (auto-resolves `session_id`):

```bash
$CLAUDE_PLUGIN_ROOT/scripts/gingko.sh append-step '<observation>' '<action>'
```

### What makes a good step

Steps are read by future-you, often months later, with no surrounding conversation. Self-contain them.

**Observation** = state of the world *before* you acted. Include the smallest unique anchor that lets future-you find the place again — file path, function name, error text, key invariant. Prefer concrete over general.

| Weak | Strong |
|---|---|
| "The tests were broken" | "`Gingko.MemoryTest` failed in `lib/gingko/memory_test.exs:142` because `start_session/1` rejected nil `agent`, but the schema marked it optional" |
| "Auth was buggy" | "Token refresh in `AuthController.refresh/2` returned 401 when the JWT clock-skew window was 0; production had skew=30s set via env" |
| "Looked at the code" | "Read `lib/gingko/mcp/tools/recall.ex` — it forwards to `Gingko.Memory.recall/1` and never validates `project_id` length" |

**Action** = what you decided/changed and *why* the alternatives were rejected. The "why" is the part that's expensive to recover later.

| Weak | Strong |
|---|---|
| "Fixed it" | "Added a guard clause `when is_binary(agent) and agent != \"\"` in `start_session/1`. Did not change the schema (would break older clients)" |
| "Refactored" | "Extracted summary rendering into `Gingko.Summaries.MarkdownRenderer` because three callers were duplicating the headline+body layout. Kept the old function as a 1-line delegate to avoid churn in tests" |
| "Added a test" | "Added regression test in `recall_test.exs:88` covering empty `project_id`. Used `assert_raise` rather than `assert match?` because the API contract is to crash, not return `{:error, _}`" |

### When to record

Record after:
- A bug fix (capture the root cause, not the symptom).
- A non-obvious decision (why option A over B).
- A meaningful refactor or rename.
- An investigation that yielded a finding, even if the bug remains open.
- Architectural choices, library selections, schema/migration decisions.
- A surprise — anything that violated your prior model of how the code worked.

### When NOT to record

- Trivial Q&A with no code change.
- Reading files without acting on them.
- Mid-step before you have a result (wait until you do).
- Information already trivially derivable from `git log` or current code state.
- Information that should live in the user's `~/.claude/.../memory/` (user preferences, workflow rules) — that belongs in CLAUDE.md / auto-memory, not Gingko.

### Granularity

One step per coherent decision. Don't bundle a five-step refactor into one giant action — future recall returns whole nodes, so an over-long action becomes a wall of unrelated content. Don't fragment either: "renamed variable" alone is noise. A useful step is roughly: one paragraph of observation, one paragraph of action.

## Quick Reference

| Goal | Call |
|---|---|
| Find prior context | `recall` (specific query) → `get_node` (drill in) |
| Skim recent learnings | `latest_memories` |
| Re-orient mid-session | `get_session_primer`, then `get_cluster` for any slug of interest |
| Record a finding | `append_step` |
| List available projects | `list_projects` |
| Check a session's state | `get_session_state` |
| Force commit before context switch | `commit_session` (returns new `session_id`) |
| Set the project's North Star | `set_charter` (markdown content) |
| On-demand summary refresh | `refresh_principal_memory` (`scope: "all" \| "state" \| "cluster"`) |
| Background graph hygiene | `run_maintenance` (`operation: "decay" \| "consolidate" \| "validate"`) |

The maintenance, charter, and refresh tools are operator-grade — only call them when the user asks.

## Failure Modes

- **Service unreachable**: every CLI subcommand exits 0 with a stderr warning; MCP calls return an error. Don't panic — the SessionStart hook already bailed silently and the user knows. Continue without memory; do not block work on it.
- **No active session**: `gingko.sh session-id` prints empty, `append-step` is a silent no-op. If the user explicitly wants something recorded, surface this to them rather than calling `start_session` yourself — the hooks should have done it.
- **Recall returns nothing**: don't infer "no prior work exists." It can mean low semantic similarity for the phrasing. Try a different query (concrete identifier, error string, file path) before concluding.
