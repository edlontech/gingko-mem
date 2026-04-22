# Summaries & Session Primer

Raw graph nodes are the ground truth, but they are too noisy and too voluminous
to hand an agent at session start. Gingko's summary layer produces derived
artifacts that compress the graph into a priming document.

The summary layer is **opt-in**. Enable it in `config.toml`:

```toml
[summaries]
enabled = true
```

When disabled, `get_session_primer`, `get_cluster`, `set_charter`, and
`refresh_principal_memory` still respond, but the underlying background workers
are dormant and clusters will not be regenerated automatically.

## The priming document

`get_session_primer` composes the following sections (in order) into a single
markdown document:

1. **Playbook** — a static tool-usage guide shipped with Gingko. Seeded as
   a `principal_memory_section` row of kind `playbook` when the project is
   first opened.
2. **Charter** *(optional)* — human-authored North Star for the project. You
   set this via the `set_charter` MCP tool or the web UI. It never expires and
   is not regenerated.
3. **Project State** — an LLM-generated rolling summary of the project's
   current state. Produced by the `PrincipalStateWorker` from the project's
   hot clusters. Regenerates on graph activity, subject to a debounce.
4. **Cluster Index** — one line per hot cluster (slug + headline). Agents
   follow up with `get_cluster(slug: ...)` to expand the relevant clusters.
5. **Recent Memories** — tail of newest raw memories, for "what just
   happened" context that summaries may not have absorbed yet.

Load the primer once at session start rather than peppering the agent with
individual `recall` calls. Call it again mid-session to re-orient.

## Clusters

A cluster is a summary of everything linked to a single `tag` node via
`:membership` edges. Gingko picks the **top K tags by membership count** (K =
`hot_tags_k`, default 15) and maintains a summary row per tag.

Each cluster row stores:

- `tag_node_id` — the underlying Mnemosyne tag.
- `slug` — stable, human-readable id for MCP callers.
- `headline` — one-line description.
- `content` — the full markdown body.
- `memory_count` — how many memories are linked via `:membership`.
- `frontmatter` — metadata, including `mode` and `latency_ms` from the last
   regeneration.

Regeneration is driven by three signals:

- **Dirty tracker** — membership changes flip the cluster to dirty.
- **Memory threshold** — `cluster_regen_memory_threshold` (default 10) new
  memories since the last regen.
- **Idle seconds** — `cluster_regen_idle_seconds` (default 1800) since the last
  membership change, so changes "settle" before summarization.

A dirty cluster whose thresholds are met is picked up by the `ClusterWorker`
and resummarized. Locked clusters (`locked = true`) are skipped; unlock one in
SQLite if you need to force a regen.

## The charter

The charter is the place to encode stable facts about the project that the
agent should always know. Typical charter contents:

- Project purpose and scope.
- Non-goals and explicit constraints.
- Team conventions, approval requirements.
- Names, glossaries, house vocabulary.

Set it via:

```
set_charter project_id="my-app" content="# My App\n..."
```

Charters support a `locked` flag in the database. Locked charters reject
`set_charter` calls with `charter_locked`. Unlock from the DB if needed.

## Forcing a regeneration

Normally the background workers drive regeneration on their own. When you
need immediate freshness — for example after a big bulk import — use
`refresh_principal_memory`:

| Scope      | Effect                                                            |
|------------|-------------------------------------------------------------------|
| `all`      | Regenerate the project state *and* every cluster. **Default.**    |
| `state`    | Regenerate only the project state summary.                        |
| `cluster`  | Regenerate one cluster identified by `cluster_slug`.              |

Refresh bypasses the normal debounce and dirty-tracker thresholds.

## Tuning the summary pipeline

Common adjustments:

- **Noisy cluster index** — lower `hot_tags_k` to show fewer, stronger
  clusters in the primer.
- **Stale summaries** — lower `cluster_regen_idle_seconds` so clusters
  resummarize sooner after activity settles.
- **Hot-loop regens** — raise `principal_regen_debounce_seconds` to throttle
  project-state regens during bursts of activity.
- **Primer too long** — lower `session_primer_recent_count` and rely on
  `recall`/`get_cluster` for drill-down instead.

## Backfilling existing projects

If you enable summaries on a project that already has a substantial graph, the
initial cluster set needs to be seeded. The `Gingko.Memory.top_tags/2` helper
returns the top-K tags by membership; a `mix gingko.summaries.backfill` task
uses it to populate cluster summary rows for existing projects. Run it once
after enabling summaries, then let the workers take over.
