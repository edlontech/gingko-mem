# Frontend Revamp — Projects Index + Tabbed Project Page

- **Date:** 2026-04-21
- **Status:** Draft for implementation
- **Scope:** Replace `ProjectMonitorLive` and `MemoryInspectorLive` with a two-page model: a card-based projects index, and a tabbed per-project page. Dev-facing observer tool; no auth, no migration period.

## Goals

1. Promote project selection from a sidebar to a first-class landing page.
2. Replace the dual Monitor/Inspector split with a single tabbed project page.
3. Make unhealthy projects spottable at a glance on the index (orphans, low confidence, staleness).
4. Reduce cross-page state duplication. One source of truth per project; tabs read from shell assigns.

## Non-goals (YAGNI)

- Project CRUD UI (register/delete/rename). Still MCP-only.
- Maintenance trigger buttons (decay / consolidate / validate). Deferred.
- ETS-backed caches for the stats aggregate. Add only if profiling shows a need.
- Search history, saved queries, per-project UI settings, mobile-first layout, auth.
- Cross-session analytics beyond the existing activity timeline.

## Routing

| Path | LiveView | Purpose |
|---|---|---|
| `/` | (redirect in `PageController.home/2`) | → `/projects` when setup ready, else `/setup` |
| `/projects` | `GingkoWeb.ProjectsLive` | Card grid landing page |
| `/projects/:project_id` | (redirect in `ProjectLive.handle_params/3`) | → `/projects/:project_id/memories` |
| `/projects/:project_id/:tab` | `GingkoWeb.ProjectLive` | Tabbed project detail |
| `/setup` | `SetupLive` | Unchanged |

`:tab` whitelist: `memories`, `search`, `graph`, `health`, `events`. Unknown values `push_patch` to `memories`.

**Removed routes:** `/projects/monitor`, `/projects/:project_id/monitor`, `/projects/:project_id/inspector`. No redirect shims; old URLs 404.

**Supported query params on `/projects/:project_id/:tab`:**

- `?node=<node_id>` — pre-select a node (Graph tab) or forward-jump from Search/Health row clicks.
- `?filter=<sessions|maintenance|recalls|all>` — pre-apply Events tab filter.
- `?session_id=<id>` — pre-apply session filter inside Events tab.

Shell's `handle_params/3` parses these and passes them as props to the active tab. Tabs never read `params` directly.

## Projects index page (`/projects`)

### Layout

Responsive card grid: `grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4`. Page header shows title and total project count. Empty state when none are registered (message, not a form — projects register via MCP).

### Card content

```
┌────────────────────────────────────────┐
│ display_name                           │
│ project_id                   (mono)    │
│ ────────────────────────────────────   │
│ 1,247 nodes · 3,108 edges              │
│ ● 2 active  ⚠ 3 orphans  91% conf     │
│ last activity · 3m ago                 │
└────────────────────────────────────────┘
```

Rendering rules:

- Clicking anywhere on the card navigates to `/projects/:project_id/memories`.
- `⚠ N orphans` rendered only when `orphan_count > 0`.
- `● N active` rendered green when `active_sessions > 0`, dimmed grey otherwise.
- `last activity` uses the existing `RelativeTime` hook.
- Cards sort by `last_activity_at` descending, ties broken by `display_name` ascending.

### Data source

Single aggregate facade call:

```elixir
@spec list_projects_with_stats() :: %{projects: [project_summary()]}

@type project_summary :: %{
  project_id: String.t(),
  display_name: String.t(),
  total_nodes: non_neg_integer(),
  total_edges: non_neg_integer(),
  orphan_count: non_neg_integer(),
  avg_confidence: float() | nil,
  active_sessions: non_neg_integer(),
  last_activity_at: DateTime.t() | nil
}
```

Implementation composes stats from the existing `project_monitor_snapshot/1` per project. **Consistency guarantee:** none across projects — each per-project snapshot is self-consistent; inter-project staleness is acceptable.

### Live updates

`ProjectsLive` subscribes to:

- `Gingko.Projects.subscribe_projects()` — for add/remove of projects (already exists).
- `Gingko.Memory.subscribe_projects_stats()` — new; thin wrapper on `Phoenix.PubSub` topic `"projects:stats"`.

Broadcasts to `"projects:stats"` are issued by a new `Gingko.Memory.ProjectStatsBroadcaster` GenServer that debounces per-project events on a 500ms window. The broadcaster lives in **Gingko's** supervision tree (not Mnemosyne's) and subscribes to each project's `project_monitor_topic/1` to derive the debounce input.

A card re-renders in place on stats broadcast — no full re-query storm.

## Project detail page (`/projects/:project_id/:tab`)

### Architecture

One LiveView (`GingkoWeb.ProjectLive`) owns the page. Each of the 5 tabs is a `Phoenix.LiveComponent`. Tab switches use `push_patch` (not `navigate`), so the shell process is not remounted between tabs.

Only the currently-active tab is rendered. Inactive tabs receive no updates.

### Shell responsibilities

1. **Mount:** read `project_id` and `:tab` from params; raise `Ecto.NoResultsError` if project unknown (→ Phoenix 404); subscribe to `Memory.project_monitor_topic(project_id)` and `Projects.subscribe_projects()`; hydrate initial snapshot.
2. **`handle_params/3`:** parse `:tab` segment (whitelist), redirect unknown to `memories`; parse query params (`node`, `filter`, `session_id`) and carry into assigns; do **not** re-subscribe or re-hydrate on tab changes.
3. **`handle_info/2`:** route `{:memory_event, %SessionMonitorEvent{}}`:
   - Update shared assigns: `recent_events` (bounded 100), `counters`, `quality`, `active_sessions`, `past_sessions`, `connection_status`.
   - If event type is in `@graph_refresh_event_types`, schedule a debounced `:refresh_memories` (500ms) — list lifted verbatim from the module attribute in today's `lib/gingko_web/live/project_monitor_live.ex`.
   - If a tab is active, `send_update/2` it so it can do incremental UI work (e.g., Events tab scrolls a new row in, Graph tab re-renders clusters on `:changeset_applied`).
4. **Render:** persistent status strip + tab bar + `<.live_component>` for the active tab only.

### Persistent status strip

```
┌── Gingko · my-project (abc-123) ─────────────────────────────┐
│  ● 2 active · 1,247 nodes · 3 orphans · 91% conf · live      │
│  [Memories] [Search] [Graph] [Health] [Events]               │
└───────────────────────────────────────────────────────────────┘
```

- `● N active` is a link that patches to `/projects/:id/events?filter=sessions`.
- Connection badge (`live` / `degraded` / `snapshot`) reuses current `status_badge_class/1` and `status_label/1`.
- Breadcrumb `← Projects` above the project name.

### Shell assigns

**Owned by shell (kept current via PubSub):**

- `project_id`, `project` (struct), `active_tab`, `active_params` (parsed query params)
- `counters`, `quality`, `active_sessions`, `past_sessions`
- `recent_events` (bounded 100)
- `recent_memories`, `memories_top_k`, `memories_refresh_timer`
- `connection_status`, `subscribed_topic`, `rehydrated_at`

**Owned by tab LiveComponents (isolated):**

- Search: `query_text`, `query_status`, `query_result`, `query_task_ref`, `touched_node_ids`.
- Graph: `layout_mode`, `expanded_cluster_id`, `selected_node_id`, `graph_view`, `expanded_node_ids`.
- Events: `expanded_event_id`, `filter_mode`, `session_id_filter`.

### Initial hydration (shell `mount/3`)

```elixir
snapshot = Memory.project_monitor_snapshot(project_id)
events = ActivityStore.list(project_id)
past = Projects.list_sessions(project_id, status: "finished")
memories = Memory.latest_memories(%{project_id: project_id, top_k: 10})
```

All existing functions — no new reads introduced. `ActivityStore` is `Gingko.Memory.ActivityStore` (already in the codebase under `lib/gingko/memory/activity_store.ex`, used today by `ProjectMonitorLive`).

## Tab components

All tabs live in `lib/gingko_web/live/project_live/`. No tab subscribes to PubSub directly. No tab issues its own snapshot read on mount — first render draws from shell assigns passed as props.

### Memories tab (`MemoriesTabComponent`)

- Absorbs the existing `RecentMemoriesComponent` rendering.
- Props from shell: `memories`, `top_k`.
- Events: `change_top_k` → informs shell, shell re-queries and `send_update`s.

### Search tab (`SearchTabComponent`)

- Single textarea + submit button.
- On submit: `Task.Supervisor.async_nolink(Gingko.TaskSupervisor, fn -> Memory.recall(...) end)`.
- Task ref is stored in shell assigns (since `Task` messages go to the LiveView process, not LiveComponents).
- Shell's `handle_info({ref, result}, ...)` matches on ref and `send_update(SearchTabComponent, ..., event: {:query_result, result})`.
- `{:DOWN, ref, :process, _, reason}` → shell forwards `{:query_error, reason}`.
- Result row click: `push_patch(to: ~p"/projects/#{id}/graph?node=#{node_id}")`.

### Graph tab (`GraphTabComponent`)

- Reuses `GraphViewportComponent` (Cytoscape shell) and `NodeInspectorComponent` (right-side panel).
- Layout-mode selector: **Force / Layered / Subgoal Tree / Provenance**. These are the 4 values passed as `view:` to `Memory.monitor_graph/1`. Subgoal Tree and Provenance — today separate Inspector tabs — become layout modes here.
- Cluster expand/collapse logic moved from `ProjectMonitorLive` and `MemoryInspectorLive` (both had copies).
- Deep-link: `?node=<id>` pre-selects on mount; updates `selected_node_id` + triggers node inspector.

### Health tab (`HealthTabComponent`)

- Top row: cards for `total_nodes`, `total_edges`, `orphan_count`, `avg_confidence`, `last_decay_at`, `last_consolidation_at`, `last_validation_at`. Source: the shell's `quality` assign, populated by `Memory.project_monitor_snapshot/1` (which already returns all seven fields — see the `default_quality/0` shape in `lib/gingko/memory.ex`).
- Two side-by-side sections: Orphans (absorbs `OrphansComponent`) and Low-Confidence (absorbs `LowConfidenceComponent`).
- Row click on either list: `push_patch(to: ~p"/projects/#{id}/graph?node=#{node_id}")`.
- Data source: existing `Memory.inspector_data/1` (kept).
- No maintenance trigger buttons in this pass.

### Events tab (`EventsTabComponent`)

- Reuses existing `ActivityFeedComponent` row rendering logic (lifted into the new component).
- Filter bar: `[All] [Sessions] [Maintenance] [Recalls]` — toggles `filter_mode`.
- With `Sessions` filter: events grouped by `session_id`. Each session row expandable inline to show its lifecycle events (`:session_started` → `:step_appended` → `:session_committed`/`:session_expired`) and its summary. Replaces the current Monitor's "Active Sessions" / "Past Sessions" / "Selection Detail" panels.
- Deep-link: `?filter=sessions&session_id=<id>` pre-applies both filters on mount.

## Data flow

### New facade functions on `Gingko.Memory`

```elixir
def list_projects_with_stats() :: %{projects: [project_summary()]}
def subscribe_projects_stats() :: :ok
def broadcast_project_stats_changed(project_id :: String.t()) :: :ok
```

`subscribe_*` / `broadcast_*` wrap Phoenix.PubSub on topic `"projects:stats"`.

### New GenServer: `Gingko.Memory.ProjectStatsBroadcaster`

- Location: `lib/gingko/memory/project_stats_broadcaster.ex`.
- Supervised by: Gingko's Memory supervision tree.
- Role: subscribes to each registered project's `project_monitor_topic/1` on startup, plus `Projects.subscribe_projects/0` so it can track projects added/removed after boot (the `:projects_changed` message it already emits). Coalesces incoming `SessionMonitorEvent`s per project on a 500ms tumbling window and emits one `"projects:stats"` broadcast per project per window. No payload — subscribers re-query `list_projects_with_stats/0` (or a per-project variant if profiling warrants later).
- Rationale: card grid must not re-render per `:step_appended` during an active session.

### Event fan-out (shell)

Shell receives `{:memory_event, %SessionMonitorEvent{}}` via the per-project PubSub topic (unchanged from today), updates shared assigns, and — if a tab is currently rendered — `send_update/2`s the tab with the event for incremental UI work.

### Async search

Task result and `:DOWN` messages go to shell's `handle_info/2`, matched by stored ref, then forwarded to `SearchTabComponent` via `send_update/2`. Late results (arriving after a tab switch) are delivered if the component is still mounted; otherwise the last result is cached in shell assigns and passed to the component on its next mount.

### Error paths

| Condition | Behaviour |
|---|---|
| Unknown `project_id` in URL | Mount raises `Ecto.NoResultsError` → Phoenix 404 |
| Unknown `:tab` segment | `handle_params/3` `push_patch` to `memories` |
| `Memory.project_monitor_snapshot/1` failure | Empty-state assigns + `put_flash(:error, ...)`, `connection_status: :degraded` |
| Search task crash | `SearchTabComponent` shows error state via `send_update` |
| Cluster expand failure | Flash + reset `expanded_cluster_id`, reload graph (same as today) |
| Mnemosyne disconnect | `connection_status: :degraded` on next `_ -> ...` PubSub clause |

## File placement

### Deleted

- `lib/gingko_web/live/memory_inspector_live.ex`
- `lib/gingko_web/live/memory_inspector_live/` (directory, all 6 components)
- `lib/gingko_web/live/project_monitor_live.ex`
- `lib/gingko_web/live/project_monitor_live/session_graph_component.ex` (no new home after sessions move to Events)
- Router entries for `/projects/monitor`, `/projects/:id/monitor`, `/projects/:id/inspector`

### Moved / renamed (logic preserved)

| From | To |
|---|---|
| `project_monitor_live/recent_memories_component.ex` | `project_live/memories_tab_component.ex` |
| `project_monitor_live/graph_viewport_component.ex` | `project_live/graph_viewport_component.ex` |
| `project_monitor_live/node_inspector_component.ex` | `project_live/node_inspector_component.ex` |
| `project_monitor_live/activity_feed_component.ex` | `project_live/events_tab_component.ex` |

### Net new

- `lib/gingko_web/live/projects_live.ex` — card grid
- `lib/gingko_web/live/project_live.ex` — tabbed shell
- `lib/gingko_web/live/project_live/search_tab_component.ex`
- `lib/gingko_web/live/project_live/graph_tab_component.ex`
- `lib/gingko_web/live/project_live/health_tab_component.ex`
- `lib/gingko/memory/project_stats_broadcaster.ex`

### Memory facade

- `list_projects_with_stats/0` — new.
- `subscribe_projects_stats/0` + `broadcast_project_stats_changed/1` — new.
- `inspector_data/1` — kept (feeds Health tab).
- All other existing functions untouched.

### Router

- `PageController.home/2` redirect target changes from `/projects/monitor` to `/projects`.
- Add `live "/projects", ProjectsLive` and `live "/projects/:project_id/:tab", ProjectLive`.
- Remove old monitor/inspector routes.

## Testing

Phoenix LiveView tests via `Phoenix.LiveViewTest`. No browser-based testing in this pass — Cytoscape graph rendering stays visually unverified, as today.

**Per-LiveView coverage:**

- `ProjectsLive`
  - renders empty state
  - renders card with all status fields
  - card click navigates to `/projects/:id/memories`
  - new-project broadcast appends a card
  - `"projects:stats"` broadcast updates a single card's fields
- `ProjectLive`
  - mount hydrates snapshot from one `project_monitor_snapshot/1` call
  - unknown tab redirects to `memories`
  - tab switch uses `push_patch` (asserted via `assert_patch`), LiveView process survives
  - status strip reflects PubSub event within the same request
  - 404 on unknown `project_id`
  - `?node=<id>` on graph tab propagates to `GraphTabComponent`
- `MemoriesTabComponent`
  - renders shell-supplied list
  - top-k change round-trips to shell and back
  - debounced refresh on `:changeset_applied`
- `SearchTabComponent`
  - submit spawns task (asserted via task sup child count)
  - result arrival via `send_update` updates UI
  - `:DOWN` sets error state
  - row click `push_patch`es to `/projects/:id/graph?node=…`
- `GraphTabComponent`
  - layout-mode switcher calls `monitor_graph/1` with correct `view:`
  - cluster expand/collapse round-trips
  - `?node=…` preselects on mount
- `HealthTabComponent`
  - renders orphans + low-confidence from `inspector_data/1`
  - row click `push_patch`es to graph tab
- `EventsTabComponent`
  - filter bar switches event set
  - sessions filter groups by `session_id`
  - expanding a session row renders lifecycle events inline
  - `?filter=sessions&session_id=…` pre-applies on mount

**Facade coverage:**

- `Memory.list_projects_with_stats/0`
  - 0 / 1 / N projects
  - aggregate fields match `project_monitor_snapshot/1` for each
- `Gingko.Memory.ProjectStatsBroadcaster`
  - rapid event burst coalesces to one broadcast per project per 500ms window
  - different projects do not coalesce into each other
  - subscribes to new project on `:projects_changed`

**Regression guardrail:** `mix precommit` must pass (compile-as-errors, deps unused check, format, full test suite). No Dialyzer gate.

## Open questions resolved

- **Cross-project consistency in `list_projects_with_stats/0`:** not required. Per-project snapshots are self-consistent; inter-project staleness is acceptable.
- **`ProjectStatsBroadcaster` supervision:** Gingko's Memory supervision tree, not Mnemosyne's.
