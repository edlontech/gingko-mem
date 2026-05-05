# LLM Cost Tracker — Design

- **Date:** 2026-05-05
- **Owner:** ycastor@edlon.tech
- **Status:** Draft (pending spec review + user review)
- **Scope:** Capture, attribute, persist, and visualize LLM/embedding usage cost across all Sycophant-mediated calls in Gingko.

---

## 1. Purpose

Give the operator three layered capabilities, in this order:

1. **Visibility** — totals and breakdowns of LLM spend over time.
2. **Attribution** — slice spend by project, session, and feature (`step_summarization`, `project_summary`, `mcp_structuring`, `embedding`, `other`) so the operator can decide what to optimize.
3. **Budgets / alerts** — *deferred*; the data model must support future budget queries with no schema change.

Today the application drives Sycophant calls from `Gingko.Memory.Summarizer`, `Gingko.Summaries.ProjectSummarizer`, and via `Mnemosyne.Adapters.SycophantLLM` / `Mnemosyne.Adapters.SycophantEmbedding` reached during MCP-driven structuring. Sycophant already populates `Sycophant.Usage` with token counts and per-component costs (`input_cost`, `output_cost`, `cache_read_cost`, `cache_write_cost`, `reasoning_cost`, `total_cost`) plus a nested `pricing` struct exposing `currency`. Cost computation is **not** the tracker's job — capture, attribute, store, and present is.

## 2. Non-goals

- No cost computation. Sycophant returns it; we record it.
- No FX conversion across currencies.
- No budget thresholds, alerts, or circuit breakers (deferred — schema supports it).
- No rollup tables. Per-call rows + on-demand `GROUP BY` only.
- No tracking of local Bumblebee embeddings that don't go through Sycophant. They emit no Sycophant telemetry; their absence is correct.
- No cross-process attribution helper (`Cost.Context.async/2` deferred until a real call site needs it).

## 3. Telemetry surface we depend on

From `Sycophant.Telemetry`:

| Event | Used | Notes |
|---|---|---|
| `[:sycophant, :request, :start]` | no | We don't need it; `:stop`/`:error` carry duration. |
| `[:sycophant, :request, :stop]` | yes | Primary success path. Metadata: `model, provider, wire_protocol, usage, response_model, response_id, finish_reason, duration`. Measurement: `%{duration: native}`. |
| `[:sycophant, :request, :error]` | yes | Failures, including provider-billed partial failures. Metadata adds `error, error_class`. |
| `[:sycophant, :stream, :chunk]` | no | Per-chunk noise; cost lands on `:stop`. |
| `[:sycophant, :embedding, :start \| :stop \| :error]` | yes | Same shape as request events. |

We **do not** modify Sycophant. The handler reads these events and tags them with our process-local attribution context.

## 4. Architecture

```
LLM caller (Worker / MCP tool)
        │  Cost.Context.with(%{project_key:, session_id:, feature:}, fn ->
        ▼
Sycophant.generate_text / generate_object / embed
        │  emits [:sycophant, :request|:embedding, :stop|:error]
        ▼
Cost.TelemetryHandler  (sync, in caller's process)
        │  reads Cost.Context.current()
        │  builds %Cost.Call{} row
        │  GenServer.cast(Cost.Recorder, {:row, row})
        ▼
Cost.Recorder (GenServer, single writer)
        │  buffers; flushes every 50 rows or 500ms
        │  Repo.insert_all(Cost.Call, rows)
        │  Phoenix.PubSub.broadcast("cost:rows", {:cost_rows, rows})
        ▼
SQLite gingko_llm_calls  ←  Cost.Pruner (Oban cron, retention)
        │
        ▼
Cost (queries) ──▶ CostLive (/cost)  &  ProjectMonitor cost strip
```

### 4.1 Module layout

```
lib/gingko/cost.ex              # Public query API for LiveViews
lib/gingko/cost/
  context.ex                    # Per-process attribution stack
  telemetry_handler.ex          # Sycophant event subscriber
  recorder.ex                   # Batching GenServer writer
  pruner.ex                     # Oban worker for retention
  call.ex                       # Ecto schema + changeset

lib/gingko_web/live/
  cost_live.ex                  # /cost dashboard
  project_live/
    cost_summary_component.ex   # Embedded strip in ProjectMonitorLive

priv/repo/migrations/
  YYYYMMDDHHMMSS_create_gingko_llm_calls.exs
```

### 4.2 Boot integration

- `Gingko.Application` adds `Gingko.Cost.Recorder` to its supervision tree.
- `Gingko.Cost.TelemetryHandler.attach/0` is called once at boot (after `Recorder` starts).
- Both no-op when `[cost_tracker] enabled = false`.
- Oban cron config gains a daily `Cost.Pruner` entry.

## 5. Data model

### 5.1 Schema — `gingko_llm_calls`

```elixir
create table(:gingko_llm_calls, primary_key: false) do
  add :id, :binary_id, primary_key: true            # UUIDv7

  # When
  add :occurred_at, :utc_datetime_usec, null: false # from system_time at :start
  add :duration_ms, :integer                        # nil if unknown

  # Provider/model
  add :provider, :string
  add :model, :string, null: false
  add :wire_protocol, :string
  add :event_kind, :string, null: false             # "request" | "embedding"

  # Outcome
  add :status, :string, null: false                 # "ok" | "error"
  add :finish_reason, :string
  add :error_class, :string
  add :response_id, :string
  add :response_model, :string

  # Tokens (nullable)
  add :input_tokens, :integer
  add :output_tokens, :integer
  add :cache_read_input_tokens, :integer
  add :cache_creation_input_tokens, :integer
  add :reasoning_tokens, :integer

  # Costs (nullable when unpriced)
  add :input_cost, :float
  add :output_cost, :float
  add :cache_read_cost, :float
  add :cache_write_cost, :float
  add :reasoning_cost, :float
  add :total_cost, :float
  add :currency, :string

  # Attribution (nullable; unattributed rows are valid)
  add :project_key, :string
  add :session_id, :string
  add :feature, :string

  timestamps(type: :utc_datetime_usec, updated_at: false)
end

create index(:gingko_llm_calls, [:occurred_at])
create index(:gingko_llm_calls, [:project_key, :occurred_at])
create index(:gingko_llm_calls, [:feature, :occurred_at])
create index(:gingko_llm_calls, [:model, :occurred_at])
```

### 5.2 Design choices

- **UUIDv7** PK gives time-ordered inserts on SQLite; primary index doubles as a recency cursor.
- **No FK** on `project_key`. (1) Embedding/structuring calls may fire before a project row exists. (2) Avoid cascade-deleting cost history when a project row is removed. (3) String-equality joins are cheap at our volume.
- **All costs nullable.** Unpriced models or pre-billable errors record tokens/timing without faking $0. The UI shows `—` and surfaces an "unpriced calls" indicator when any window contains them.
- **`currency` per row, not table-level.** Multi-currency-ready without future migration.
- **No `tags JSON`.** YAGNI; add when a real consumer asks.
- **Composite indexes** put `occurred_at` second so a time-range filter narrows before the `GROUP BY` dimension.

## 6. Attribution: `Cost.Context`

### 6.1 Mechanism

Per-process attribution stored in the process dictionary. Telemetry handlers run in the caller's process, so `current/0` in the handler sees what the caller pushed.

```elixir
defmodule Gingko.Cost.Context do
  @key :gingko_cost_context

  @type attrs :: %{
          optional(:project_key) => String.t(),
          optional(:session_id) => String.t(),
          optional(:feature) => atom() | String.t()
        }

  @spec with(attrs(), (-> result)) :: result when result: var
  def with(attrs, fun) when is_map(attrs) and is_function(fun, 0) do
    previous = Process.get(@key, %{})
    Process.put(@key, Map.merge(previous, attrs))

    try do
      fun.()
    after
      if previous == %{}, do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @spec current() :: attrs()
  def current, do: Process.get(@key, %{})
end
```

### 6.2 Why process dictionary

- **Logger metadata**: couples cost to logging config; many libraries scribble in there.
- **ETS**: global, races concurrent calls, wrong scope.
- **Process dict**: exact scope (this call only), free propagation to in-process callees, restored on exit.

The `try/after` makes nested `with/2` calls compose: a `feature` push inside an outer `project_key` push merges and restores correctly.

### 6.3 Attribution boundaries

| Call site | Wrap point | Sets |
|---|---|---|
| `Gingko.Memory.summarize_step/1` (the entry that drives `Memory.Summarizer`) | wrap the body | `project_key`, `session_id`, `feature: :step_summarization` |
| `Gingko.Summaries.ProjectSummaryWorker` (Oban worker) | top of `perform/1` | `project_key`, `feature: :project_summary` |
| `Memory.Summarizer.parallel_extract/1` (spawns chunk tasks via `Task.Supervisor.async_stream_nolink`) | capture `Cost.Context.current()` before async, re-apply inside each task closure | inherits from caller |
| Embedding calls inside the above paths | inherited from outer `with/2` | inherited |
| MCP `append_step` tool handler | **not wrapped** — `Mnemosyne.append_async/3` hands the structuring work to a Mnemosyne-owned process, so a per-process context set in the MCP handler does not propagate. Bridging this requires an attribution-aware Mnemosyne adapter, which is out of scope. MCP-driven calls land in the dashboard as `(unattributed)` until that bridge exists. | none |
| Anywhere else | none | row recorded with attribution `nil` |

### 6.4 Caveats

- Calls that hop processes inside a `Cost.Context.with/2` lose attribution unless the spawn point captures and re-applies. `Memory.Summarizer.parallel_extract/1` is one such site we wrap from day one (see §6.3). Other future sites (e.g. ad-hoc `Task.async` callers) will surface as `(unattributed)` rows until similarly wrapped. We do **not** build a generic `Cost.Context.async/2` helper today — capture + re-apply at the spawn point is two lines and keeps the abstraction explicit.
- Unattributed rows surface in the dashboard as `(unattributed)` — the right signal that a boundary is missing.

## 7. Ingestion path

### 7.1 `Cost.TelemetryHandler`

- Attaches once via `:telemetry.attach_many/4` to the four events in §3.
- `handle_event/4` body wrapped in `try/rescue`; any exception is logged at `:warning` and the row is dropped. **Never propagate to caller.**
- Builds a row map from event metadata + measurements + `Cost.Context.current()`.
- `GenServer.cast(Cost.Recorder, {:row, row})` — never `call`. Cost recording must not block LLM callers.

Field mapping:

| Source | Target |
|---|---|
| event name `[:sycophant, :request, _]` | `event_kind = "request"` |
| event name `[:sycophant, :embedding, _]` | `event_kind = "embedding"` |
| event name suffix `:stop` | `status = "ok"` |
| event name suffix `:error` | `status = "error"` |
| meta.model | `model` |
| meta.response_model | `response_model` |
| meta.provider | `provider` |
| meta.wire_protocol | `wire_protocol` |
| meta.response_id | `response_id` |
| meta.finish_reason | `finish_reason` |
| meta.error_class | `error_class` |
| measurement.duration (native) | `duration_ms` (converted) |
| meta.usage.input_tokens etc. | `input_tokens` etc. |
| meta.usage.input_cost etc. | `input_cost` etc. |
| meta.usage.pricing.currency | `currency` |
| `Cost.Context.current()` | `project_key`, `session_id`, `feature` |
| `now()` | `occurred_at`, `inserted_at` |

When `usage` is nil, all token/cost fields are nil but the row is still recorded.

### 7.2 `Cost.Recorder`

Single-writer GenServer. State: `%{buffer: [row, ...], flush_timer: ref | nil}`.

```
cast {:row, row}:
  buffer = [row | buffer]
  if length(buffer) >= batch_size_max → flush_now()
  else if flush_timer == nil → schedule_flush(flush_interval_ms)

info :flush:
  Repo.insert_all(Cost.Call, Enum.reverse(buffer))
  Phoenix.PubSub.broadcast(Gingko.PubSub, "cost:rows", {:cost_rows, rows})
  state with empty buffer, no timer

terminate(_reason, state):
  if state.buffer != [] → best-effort flush with timeout
```

Properties:
- ≤500ms dashboard latency.
- ≤500ms or 50-row loss on crash. Acceptable for cost telemetry.
- Single writer eliminates SQLite write contention.
- Soft mailbox cap: when `message_queue_len > 5_000`, flush immediately and log a warning. Single-user volume should never trigger; the cap is insurance.

### 7.3 `Cost.Pruner`

- Oban worker, scheduled daily via `Oban.Plugins.Cron`.
- Reads `[cost_tracker] retention_days` from `Settings`.
- `retention_days = 0` or unset → no-op.
- Otherwise: `Cost.Call |> where([c], c.inserted_at < ^cutoff) |> Repo.delete_all()` in one transaction.
- If volume ever needs chunked deletion we add it then.

## 8. Public query API — `Gingko.Cost`

Functions consumed by the LiveViews. All accept a `filter` map and return shapes the UI can render directly.

```elixir
@type filter :: %{
        optional(:from) => DateTime.t(),
        optional(:to) => DateTime.t(),
        optional(:project_key) => String.t() | [String.t()],
        optional(:feature) => String.t() | [String.t()],
        optional(:model) => String.t() | [String.t()],
        optional(:status) => String.t()
      }

@spec totals(filter) :: %{
        by_currency: [%{currency: String.t(), total_cost: float, calls: integer, ...}],
        unpriced_count: integer,
        ok_count: integer,
        error_count: integer,
        total_input_tokens: integer,
        total_output_tokens: integer,
        total_cache_tokens: integer
      }

@spec breakdown_by(filter, dimension :: :project_key | :feature | :model, opts :: keyword) ::
        [%{key: String.t() | nil, total_cost: float, calls: integer, currency: String.t()}]

@spec recent_calls(filter, opts :: keyword) :: [%Cost.Call{}]

@spec time_series(filter, bucket :: :hour | :day) ::
        [%{bucket_at: DateTime.t(), currency: String.t(), total_cost: float, calls: integer}]
```

Currency-mixing rule: every aggregation that returns a cost groups by currency. Costs are never summed across currencies.

Unpriced rule: rows with `total_cost = nil` are *counted* in `unpriced_count` and *excluded* from cost sums (not coerced to 0).

## 9. UI

### 9.1 `/cost` (CostLive) — global view

Single LiveView, single page, four stacked regions.

**Top bar — range and filters.**
- Range picker: `24h` / `7d` / `30d` / `custom`. Default `7d`.
- Multi-select filters (default = all): project, model, feature, status.
- Indicator: "showing N calls, K unpriced".

**KPI cards (4 across).**
- Total cost in window, **per currency** (one card per currency present).
- Total calls split into ok / error.
- Total tokens split into input / output / cache.
- Average cost per priced call.

**Three side-by-side breakdowns.**
- By project — bar list, descending by total cost. Click row → adds project filter.
- By feature — same shape.
- By model — same shape.

**Recent calls table.**
- Last 50 rows in window, paginated. Columns: `occurred_at`, project, session, feature, model, status, in/out tokens, total_cost, duration.
- Row-click expands to show response_id, error_class, individual cost components.

**Live updates.** Subscribes to `"cost:rows"`. Filter-matched rows update KPIs and prepend to the recent table without re-querying. Filter changes trigger a single re-aggregation.

**Empty state.** First load with zero rows → "No LLM calls recorded yet. The tracker captures Sycophant requests and embeddings — try running a project summary."

### 9.2 Cost strip (in `ProjectMonitorLive`)

A small component, top-right of the existing graph view. Three values for the current project:

```
Cost  •  $0.42 last 24h  •  $1.18 last 7d  •  $4.31 last 30d
```

- Currency-aware: if rows for this project mix currencies, shows `—` rather than fake-summing.
- Click → navigates to `/cost?project_key=<key>` (URL-encoded).
- Implemented as a stateless `Phoenix.Component` (snapshot at render). It does **not** subscribe to `"cost:rows"`; the strip refreshes when the parent LiveView re-renders. The `/cost` dashboard is where live updates land. Promoting the strip to a `LiveComponent` with its own subscription is a future enhancement once a real "must-be-live" use case appears.
- No charts. The strip is a glance; `/cost` is for analysis.

## 10. Configuration

`config.toml`:

```toml
[cost_tracker]
enabled = true              # default true
retention_days = 0          # 0 = keep forever
batch_size_max = 50
flush_interval_ms = 500
```

- Loaded by `Gingko.Settings`.
- Read at boot by `Recorder`; changes require restart.
- `enabled = false` → telemetry handler not attached, Recorder not started, table just stays empty.

## 11. Error handling and edge cases

| Case | Behavior |
|---|---|
| Telemetry handler raises | rescued, logged warn, row dropped, caller unaffected |
| `Recorder` not started / dead | `GenServer.cast` to a dead named process raises `:noproc`; the handler's `try/rescue` swallows it. Rows lost until Recorder restarts. |
| `usage = nil` on `:stop` | row recorded with token/cost fields nil |
| `usage` present, no `pricing` | row recorded with tokens but `total_cost = nil` (counted as unpriced) |
| Unrecognized metadata fields | ignored |
| `project_key` not in `projects` table | row still recorded; dashboard groups by string |
| Mailbox grows past 5_000 | flush immediately, log warning |
| Mixed currencies in a window | per-currency KPI cards; never summed |
| Shutdown with buffered rows | `terminate/2` best-effort flush within timeout |
| `retention_days = 0` | Pruner is a no-op |

## 12. Testing

### 12.1 Unit

- **`Cost.Context`**: `with/2` set/restore on success and on raise; nesting merges and restores; fresh process empty.
- **`Cost.TelemetryHandler`**: drive each event shape via `:telemetry.execute/3` against a stub recorder process. Cases: full Usage; error; embedding stop; `usage = nil`; pricing missing → `total_cost = nil`. Malformed metadata must not crash the test process.

### 12.2 Integration (real DB)

- **`Cost.Recorder`**: single-row insert + PubSub; batch trigger flush; timer flush; `terminate/2` flush. Timing and batch-size config injected via `Settings` accessor stubbed with Mimic — no `Application.put_env` (per project conventions).
- **`Gingko.Cost`** queries: seed deterministic dataset (3 projects × 2 models × 2 features × 7 days). Each public function gets a happy-path test for shape and ordering plus one filter-combination test. Currency-mixing test (USD + EUR) must return per-currency results, never summed. Unpriced rows test must count them in `unpriced_count` and exclude from cost sums.
- **`Cost.Pruner`**: rows older/newer than cutoff; assert old gone, new kept; `retention_days = 0` no-op.

### 12.3 LiveView

- **`CostLive`**: mount with seeded rows renders KPIs, breakdowns, recent table; filter changes update KPIs; `{:cost_rows, [...]}` updates KPIs without re-query; empty state.
- **Cost strip**: mounts inside ProjectMonitorLive; shows three windowed totals scoped to current project; only reacts to matching `project_key`.

### 12.4 End-to-end

One test driving `Memory.Summarizer.perform/1` with a mocked Sycophant adapter (the project already has `test/support/mnemosyne/mock_llm.ex`). Asserts a row lands with the expected `project_key`, `feature`, `model`, and `total_cost`. This is the test that catches "we wired the boundary but forgot to call `Cost.Context.with/2` in the worker".

## 13. Out of scope (explicit)

- Budget thresholds and alerts. Schema supports them; no logic today.
- FX conversion across currencies.
- Daily/hourly rollup tables.
- `Cost.Context.async/2` cross-process helper.
- Tracking local Bumblebee embeddings that don't go through Sycophant.
- Streaming chunk-level metrics.

## 14. Open questions

None at design time. If implementation surfaces a Sycophant metadata shape that doesn't match §7.1, the handler logs and drops — no schema migration is forced.

## 15. Implementation order (rough)

Detailed plan follows in a separate document. High-level sequence:

1. Schema + migration + `Cost.Call`.
2. `Cost.Context` + tests.
3. `Cost.Recorder` + tests.
4. `Cost.TelemetryHandler` + tests.
5. Boot wiring (Application, attach, settings).
6. `Gingko.Cost` query API + tests.
7. `CostLive` + cost strip + LiveView tests.
8. `Cost.Pruner` + Oban cron wiring + tests.
9. Wrap attribution boundaries (Memory.Summarizer, ProjectSummarizer, MCP append_step).
10. End-to-end test.
