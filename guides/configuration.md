# Configuration

Gingko has a single configuration file: `$GINGKO_HOME/config.toml` (default
`~/.gingko/config.toml`). The file is created on first boot with safe defaults.

All values can be edited in the `/setup` UI or by hand. On restart, the server
re-parses the file and rebuilds runtime adapters.

API keys are **never** stored in the file. Only the environment-variable names
to read are persisted; set the keys in your shell or process manager.

## Application home

- Default: `~/.gingko`.
- Override: set `GINGKO_HOME=/custom/path` before starting the server.
- Contents:
  - `config.toml`
  - `memory/` — Mnemosyne DETS files, one subdir per project.
  - `metadata.sqlite3` — project and session metadata, summary rows.

## Sections

### `[paths]`

```toml
[paths]
memory = "memory"        # Relative to GINGKO_HOME, or an absolute path.
```

### `[llm]`

Controls the chat LLM used during extraction and summary generation.

```toml
[llm]
provider = "anthropic"               # Must be listed by LLMDB/Sycophant.
model    = "claude-sonnet-4"         # Bare name, or "provider:model".
```

The API key is read from `${PROVIDER}_API_KEY` (e.g. `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY`) based on your provider.

### `[embeddings]`

Controls the embedding model used for recall.

```toml
[embeddings]
provider = "bumblebee"               # or "openai", etc.
model    = "intfloat/e5-base-v2"     # Provider-specific.
```

- `bumblebee` runs entirely locally via Nx. On macOS it uses EMLX; on Linux it
  uses EXLA. First use downloads the model.
- Any other provider hits a remote API and needs the corresponding
  `${PROVIDER}_API_KEY`.

### `[server]`

```toml
[server]
host = "127.0.0.1"
port = 8008
```

### `[mnemosyne]`

Controls the extraction pipeline and session lifecycle.

```toml
[mnemosyne]
intent_merge_threshold    = 0.8
intent_identity_threshold = 0.95
refinement_threshold      = 0.6
refinement_budget         = 1
plateau_delta             = 0.05
extraction_profile        = "none"   # "none", "coding", "research", "customer_support"
consolidation_threshold   = 0.85
decay_threshold           = 0.1
auto_commit               = true
flush_timeout_ms          = 120_000
session_timeout_ms        = 600_000
trace_verbosity           = "summary"   # "summary" or "detailed"
```

Key knobs:

- `auto_commit` — sessions commit automatically when they end. Disable only if
  you want every commit to be explicit via `close_async`/`commit_session`.
- `flush_timeout_ms` — how long a queued flush can take before it is treated
  as failed. Tune up if your LLM is slow.
- `session_timeout_ms` — idle sessions beyond this are swept and finalized.
- `extraction_profile` — global default extraction preset. Projects can override
  it individually; see [Extraction Profiles](extraction-profiles.md).
- `consolidation_threshold` — semantic similarity required to merge two
  semantic nodes during `run_maintenance operation="consolidate"`.
- `decay_threshold` — utility score under which a node is pruned during
  `run_maintenance operation="decay"`.

### `[episodic_validation]`

Penalties applied when validating that abstract nodes are grounded in
episodic evidence.

```toml
[episodic_validation]
validation_threshold   = 0.3
orphan_penalty         = 0.3
weak_grounding_penalty = 0.1
```

### `[summaries]`

Derived-memory pipeline. See [Summaries & Session Primer](summaries-and-primer.md).

```toml
[summaries]
enabled                           = false   # set true to turn on the summary layer
hot_tags_k                        = 15
cluster_regen_memory_threshold    = 10
cluster_regen_idle_seconds        = 1800
principal_regen_debounce_seconds  = 60
session_primer_recent_count       = 15
```

### `[overrides]` — pipeline step models

Each extraction step can point at a different model or pass custom options.
Unspecified steps inherit `[llm]`.

Available steps:

```
structuring extract retrieval summarize merge_intent
get_refined_query get_semantic get_procedural get_state
get_subgoal get_plan get_mode get_reward get_return
reason_semantic reason_procedural reason_episodic
```

Example — use a cheaper model for retrieval scoring:

```toml
[overrides.retrieval]
model = "openai:gpt-4o-mini"

[overrides.retrieval.opts]
temperature = 0.0
max_tokens  = 512
```

### `[value_function.params]` — retrieval tuning

Per-node-type parameters that shape recall. Defaults are sensible for most
projects; tune only after observing bad retrieval quality. See
[Maintenance & Tuning](maintenance-and-tuning.md#value-function-tuning).

Node types: `semantic`, `procedural`, `episodic`, `subgoal`, `tag`, `source`,
`intent`. Each has:

```toml
[value_function.params.semantic]
threshold  = 0.0
top_k      = 20
lambda     = 0.01
k          = 5
base_floor = 0.3
beta       = 1.0
```

## Validation

On load, Gingko validates:

- `llm.provider`, `llm.model`, `embeddings.provider`, `embeddings.model` are
  present.
- For non-`bumblebee` embeddings, the model string resolves via Sycophant.
- LLM model string resolves via Sycophant (provider-qualified form accepted).

Validation failures show on `/setup` as actionable issues; the server will not
start extraction until they are resolved.

## Restart semantics

Changes to `[llm]`, `[embeddings]`, `[server]`, or `[overrides]` require a
server restart to rebuild adapters. Threshold and timeout changes under
`[mnemosyne]`, `[summaries]`, `[episodic_validation]`, and
`[value_function.params]` take effect on the next project open; use
`Gingko.Memory.reload_project_config/1` (called when saving project-scoped
settings from the UI) to pick them up without a restart.
