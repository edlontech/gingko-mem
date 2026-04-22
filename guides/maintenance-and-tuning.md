# Maintenance & Tuning

Memory graphs grow; left unchecked they accumulate near-duplicates, low-value
nodes, and poorly-grounded abstractions. Gingko exposes three maintenance
operations and a per-type value function you can tune to keep retrieval sharp.

## Maintenance operations

All three run asynchronously on Mnemosyne's maintenance lane. Kick them off
with the `run_maintenance` MCP tool or call
`Gingko.Memory.run_maintenance/1` directly.

### `decay`

Prunes low-utility nodes. Utility is scored from recency, frequency, and the
reward signals produced during extraction. Nodes below the configured
threshold are deleted.

```toml
[mnemosyne]
decay_threshold = 0.1   # Lower = prune less; higher = prune more.
```

When to run:

- Periodically on long-lived projects (e.g. weekly cron).
- Before exporting or sharing a project — cleans out rough drafts.

### `consolidate`

Merges near-duplicate semantic nodes using embedding cosine similarity. Two
nodes above the threshold are merged into one, preserving the union of their
links.

```toml
[mnemosyne]
consolidation_threshold = 0.85
```

When to run:

- After large ingestion batches that may have produced many near-identical
  facts.
- When recall starts returning multiple variants of the same memory.

Err on the high side (0.85–0.95) — too low and genuinely distinct nodes get
collapsed.

### `validate`

Penalizes abstract nodes (semantic, procedural) that lack sufficient episodic
grounding. Abstract nodes without episodic provenance are suspect — they may
be hallucinations or poorly-extracted stubs. Validation reduces their utility
so they decay faster.

```toml
[episodic_validation]
validation_threshold   = 0.3    # min grounding ratio to pass
orphan_penalty         = 0.3    # applied when no episodic provenance exists
weak_grounding_penalty = 0.1    # applied when grounding exists but is thin
```

When to run:

- After periods of heavy extraction with a weak LLM.
- Before a consolidation pass, so the good nodes "win" during merges.

## Recommended cadence

For a single-project dev workflow:

- `validate` after every ~50 sessions.
- `consolidate` every few weeks, after validating.
- `decay` monthly.

For a multi-project production server:

- Schedule each operation per project on a rolling cron.
- Start gentle (thresholds conservative) and tighten once you trust the
  outcome.

## Value-function tuning

Recall ranks candidate nodes using a value function with six parameters per
node type. Defaults live in `Gingko.Settings.value_function_defaults/0` and
can be overridden in `config.toml` under `[value_function.params.<type>]`.

| Param        | Meaning                                                                 |
|--------------|-------------------------------------------------------------------------|
| `threshold`  | Minimum similarity score for a node to be considered at all.            |
| `top_k`      | Hard cap on candidates returned per type.                               |
| `lambda`     | Recency decay rate. Higher = older nodes fade faster.                   |
| `k`          | Shape parameter for the frequency-reward blend.                         |
| `base_floor` | Minimum base value applied even when other signals are weak.            |
| `beta`       | Weight of the reward signal vs similarity.                              |

### When to tune which type

- `semantic` — the workhorse. Tune `top_k` first if recall misses obvious
  facts; tune `threshold` down to cast a wider net.
- `episodic` — the narrative layer. High `top_k` (30+) is fine when you want
  context-rich recall.
- `procedural` — raise `threshold` if recall returns too many tangentially-
  related recipes.
- `subgoal` / `intent` — these are usually a few per session, so `top_k` of
  10 is plenty.
- `tag` — used by the cluster layer, not typically a direct recall target.
  High `threshold` (0.9) keeps tag retrieval tight.
- `source` — external anchors. Large `top_k` (50+) is fine because sources are
  cheap to include.

### Per-project overrides

Set `value_function_overrides` in the project's extraction overlay to override
these per type without touching the global config. See
[Extraction Profiles](extraction-profiles.md#per-project-overlays).

## Observability

Mnemosyne emits telemetry events for every extraction step and maintenance
pass. Gingko's `TelemetryBridge` turns those into PubSub messages consumed by
the web UI:

- `/projects/monitor` shows live session state, graph growth, and derived
  metrics.
- The project-card grid on `/` surfaces `total_nodes`, `total_edges`,
  `orphan_count`, and `avg_confidence` per project.

When a maintenance operation is queued, its result arrives via notifier
events — subscribe to the project's monitor topic
(`Gingko.Memory.project_monitor_topic/1`) to observe it.
