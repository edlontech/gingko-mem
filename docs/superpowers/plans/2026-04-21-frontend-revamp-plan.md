# Frontend Revamp Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `ProjectMonitorLive` and `MemoryInspectorLive` with a card-based projects index at `/projects` and a tabbed project page at `/projects/:project_id/:tab`.

**Design:** [docs/superpowers/specs/2026-04-21-frontend-revamp-design.md](../specs/2026-04-21-frontend-revamp-design.md)

**Architecture:** One LiveView per page. `ProjectsLive` renders a card grid driven by a new `Memory.list_projects_with_stats/0` aggregate. `ProjectLive` is a shell LiveView owning the per-project PubSub subscription, snapshot, and status strip; each of the 5 tabs (`memories`, `search`, `graph`, `health`, `events`) is a `Phoenix.LiveComponent` mounted only when active. A new `ProjectStatsBroadcaster` GenServer debounces per-project events for the index page. Old LiveViews are deleted in a final teardown task, not migrated in-place.

**Tech Stack:** Elixir, Phoenix LiveView, DaisyUI, Mnemosyne, Cytoscape.js.

**Required skills during execution:**
- `@superpowers:test-driven-development` — test-first for every task.
- `@elixir:phoenix-thinking` — whenever touching LiveView `mount`/`handle_params`/`handle_info`.
- `@elixir:otp-thinking` — for the new `ProjectStatsBroadcaster` GenServer.
- `@superpowers:verification-before-completion` — `mix precommit` at task end before calling anything done.

**Ordering note:** Tasks 1–8 can coexist with the old LiveViews. Task 9 is the only destructive step; it deletes the old code once the new surface is fully wired. If any earlier task breaks the old monitor/inspector, fix it in that task — do not defer to teardown.

---

## Task 1: Memory facade + `ProjectStatsBroadcaster`

**Files:**
- Modify: `lib/gingko/memory.ex` — add `list_projects_with_stats/0`, `subscribe_projects_stats/0`, `broadcast_project_stats_changed/1`
- Create: `lib/gingko/memory/project_stats_broadcaster.ex`
- Modify: `lib/gingko/application.ex` — supervise the broadcaster
- Test: `test/gingko/memory_test.exs` (add cases)
- Test: `test/gingko/memory/project_stats_broadcaster_test.exs` (new)

**What to build:**

The aggregate query powering the `/projects` card grid, and a GenServer that debounces per-project `SessionMonitorEvent`s into a single `"projects:stats"` broadcast per 500ms window per project.

No cross-project consistency is required — each per-project snapshot is self-consistent; stale-between-projects data is acceptable (see spec, §Data flow). The broadcaster lives in **Gingko's** supervision tree (not Mnemosyne's); order it after `ActivityStore` and before `MnemosyneSupervisor`.

Test strategy:
- `list_projects_with_stats/0` with 0, 1, and 2 projects; each field matches what `project_monitor_snapshot/1` returns for that project. Assert `active_sessions`, `total_nodes`, `total_edges`, `orphan_count`, `avg_confidence`, `last_activity_at` shape.
- Broadcaster: rapid burst of 10 events for project A within 500ms produces exactly one `"projects:stats"` message. Events for project B in the same window produce a separate broadcast. New project registered post-boot triggers subscription to its topic (subscribe to `Projects.subscribe_projects/0` on startup).

**Implementation:**

```elixir
# lib/gingko/memory.ex (append to existing module)

@projects_stats_topic "projects:stats"

def projects_stats_topic, do: @projects_stats_topic

def subscribe_projects_stats do
  Phoenix.PubSub.subscribe(Gingko.PubSub, @projects_stats_topic)
end

def broadcast_project_stats_changed(project_id) when is_binary(project_id) do
  Phoenix.PubSub.broadcast(
    Gingko.PubSub,
    @projects_stats_topic,
    {:project_stats_changed, project_id}
  )
end

@spec list_projects_with_stats() :: %{projects: [map()]}
def list_projects_with_stats do
  projects =
    Projects.list_projects()
    |> Enum.map(fn project ->
      snapshot = project_monitor_snapshot(project.project_key)
      quality = Map.get(snapshot, :quality, default_quality())
      counters = Map.get(snapshot, :counters, %{})
      active = Map.get(snapshot, :active_sessions, [])

      last_activity =
        active
        |> Enum.map(& &1.latest_activity_at)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> project_last_activity_fallback(project.project_key)
          timestamps -> Enum.max(timestamps, DateTime)
        end

      %{
        project_id: project.project_key,
        display_name: project.display_name || project.project_key,
        total_nodes: quality.total_nodes,
        total_edges: quality.total_edges,
        orphan_count: quality.orphan_count,
        avg_confidence: quality.avg_confidence,
        active_sessions: Map.get(counters, :active_sessions, length(active)),
        last_activity_at: last_activity
      }
    end)

  %{projects: projects}
end

defp project_last_activity_fallback(project_key) do
  case Projects.list_sessions(project_key, status: "finished") do
    [session | _] -> session.finished_at || session.started_at
    _ -> nil
  end
rescue
  _ -> nil
end
```

```elixir
# lib/gingko/memory/project_stats_broadcaster.ex

defmodule Gingko.Memory.ProjectStatsBroadcaster do
  @moduledoc """
  Debounces per-project `SessionMonitorEvent`s into one `projects:stats`
  broadcast per 500ms window per project. Powers the `/projects` card grid
  without re-rendering per step_appended.
  """

  use GenServer

  alias Gingko.Memory
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects

  @debounce_ms 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Projects.subscribe_projects()

    for project <- Projects.list_projects() do
      Phoenix.PubSub.subscribe(
        Gingko.PubSub,
        Memory.project_monitor_topic(project.project_key)
      )
    end

    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_info({:memory_event, %SessionMonitorEvent{project_id: project_id}}, state)
      when is_binary(project_id) do
    {:noreply, schedule(state, project_id)}
  end

  @impl true
  def handle_info(:projects_changed, state) do
    for project <- Projects.list_projects() do
      topic = Memory.project_monitor_topic(project.project_key)
      Phoenix.PubSub.subscribe(Gingko.PubSub, topic)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:flush, project_id}, state) do
    Memory.broadcast_project_stats_changed(project_id)
    {:noreply, %{state | timers: Map.delete(state.timers, project_id)}}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  defp schedule(%{timers: timers} = state, project_id) do
    if timers[project_id] do
      state
    else
      ref = Process.send_after(self(), {:flush, project_id}, @debounce_ms)
      %{state | timers: Map.put(timers, project_id, ref)}
    end
  end
end
```

```elixir
# lib/gingko/application.ex — insert after `Gingko.Memory.ActivityStore`
Gingko.Memory.ActivityStore,
Gingko.Memory.GraphCluster,
Gingko.Memory.ProjectStatsBroadcaster,
```

**Testing:**

```
mix test test/gingko/memory_test.exs test/gingko/memory/project_stats_broadcaster_test.exs
```

Expected: all new cases pass. Burst test uses `Phoenix.PubSub.subscribe/2` + `assert_receive` with a 700ms timeout to confirm exactly one message after the debounce window.

**Commit:**
```bash
git add lib/gingko/memory.ex lib/gingko/memory/project_stats_broadcaster.ex lib/gingko/application.ex test/gingko/memory_test.exs test/gingko/memory/project_stats_broadcaster_test.exs
git commit -m "feat: add project stats aggregate and debouncer"
```

---

## Task 2: `ProjectsLive` card grid landing page

**Files:**
- Create: `lib/gingko_web/live/projects_live.ex`
- Modify: `lib/gingko_web/router.ex` — add `live "/projects", ProjectsLive` (keep old routes for now)
- Modify: `lib/gingko_web/controllers/page_controller.ex` — change redirect target from `/projects/monitor` to `/projects`
- Test: `test/gingko_web/live/projects_live_test.exs` (new)

**What to build:**

A responsive card grid at `/projects`. Cards show `display_name`, `project_id` (monospaced), and a compact status row (nodes, edges, orphans badge if >0, active-sessions pill, avg confidence, last activity). Cards sort by `last_activity_at` desc, ties by `display_name` asc. Clicking a card navigates to `/projects/:project_id/memories`.

Subscribe to `Projects.subscribe_projects()` and `Memory.subscribe_projects_stats()` on connected mount. On either message, re-query `Memory.list_projects_with_stats/0` and reassign `:projects`. Empty state when the list is empty.

Do **not** remove the old `/projects/monitor` route in this task — leave it functional until Task 9.

Test strategy:
- `mount` renders empty state when no projects.
- Two projects render two cards in correct sort order.
- Card markup includes all seven fields (`display_name`, `project_id`, nodes, edges, orphans-when->0, active-sessions, avg-conf, last-activity).
- Card click → `assert_patch`/`assert_redirect` to `/projects/:id/memories`.
- A `{:project_stats_changed, pid}` message triggers re-render with updated numbers.
- `:projects_changed` triggers re-render with new project appended.

**Implementation:**

```elixir
defmodule GingkoWeb.ProjectsLive do
  use GingkoWeb, :live_view

  alias Gingko.Memory
  alias Gingko.Projects

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Projects.subscribe_projects()
      Memory.subscribe_projects_stats()
    end

    {:ok, assign_projects(socket)}
  end

  @impl true
  def handle_info({:project_stats_changed, _project_id}, socket) do
    {:noreply, assign_projects(socket)}
  end

  @impl true
  def handle_info(:projects_changed, socket) do
    {:noreply, assign_projects(socket)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-[112rem] px-4 py-6 sm:px-6 lg:px-8">
      <.header>
        Projects
        <:subtitle>{length(@projects)} registered</:subtitle>
      </.header>

      <div :if={Enum.empty?(@projects)} class="mt-6 rounded-2xl border border-dashed border-base-300 bg-base-100 p-6 text-sm text-base-content/70">
        No projects registered. Open one via MCP to get started.
      </div>

      <div
        :if={not Enum.empty?(@projects)}
        class="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
      >
        <.link
          :for={project <- @projects}
          navigate={~p"/projects/#{project.project_id}/memories"}
          class="rounded-2xl border border-base-300 bg-base-100 p-4 transition hover:border-primary hover:bg-base-200"
        >
          <p class="text-lg font-semibold">{project.display_name}</p>
          <p class="font-mono text-xs text-base-content/60">{project.project_id}</p>

          <div class="mt-3 border-t border-base-200 pt-3 text-xs text-base-content/80">
            <p>{project.total_nodes} nodes · {project.total_edges} edges</p>
            <p class="mt-1 flex flex-wrap items-center gap-2">
              <span class={["inline-flex items-center gap-1", active_class(project.active_sessions)]}>
                ● {project.active_sessions} active
              </span>
              <span :if={project.orphan_count > 0} class="badge badge-warning badge-sm">
                ⚠ {project.orphan_count} orphans
              </span>
              <span :if={project.avg_confidence}>
                {Float.round(project.avg_confidence * 100, 1)}% conf
              </span>
            </p>
            <p :if={project.last_activity_at} class="mt-1 text-base-content/50">
              last activity ·
              <span
                phx-hook="RelativeTime"
                id={"last-activity-#{project.project_id}"}
                data-timestamp={DateTime.to_iso8601(project.last_activity_at)}
              >
                {Calendar.strftime(project.last_activity_at, "%Y-%m-%d %H:%M")}
              </span>
            </p>
          </div>
        </.link>
      </div>
    </section>
    """
  end

  defp assign_projects(socket) do
    %{projects: projects} = Memory.list_projects_with_stats()
    assign(socket, :projects, sort(projects))
  end

  defp sort(projects) do
    Enum.sort_by(projects, fn p ->
      {
        -unix_micros(p.last_activity_at),
        p.display_name
      }
    end)
  end

  defp unix_micros(nil), do: 0
  defp unix_micros(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp active_class(n) when n > 0, do: "text-success"
  defp active_class(_), do: "text-base-content/40"
end
```

Router addition (keep old routes untouched):
```elixir
live "/projects", ProjectsLive
```

Page controller: change `/projects/monitor` → `/projects` in the `redirect(conn, to: ...)` line.

**Testing:**
```
mix test test/gingko_web/live/projects_live_test.exs
```

**Commit:**
```bash
git add lib/gingko_web/live/projects_live.ex lib/gingko_web/router.ex lib/gingko_web/controllers/page_controller.ex test/gingko_web/live/projects_live_test.exs
git commit -m "feat: add projects index card grid"
```

---

## Task 3: `ProjectLive` shell + routing

**Files:**
- Create: `lib/gingko_web/live/project_live.ex`
- Modify: `lib/gingko_web/router.ex` — add `live "/projects/:project_id/:tab", ProjectLive`
- Test: `test/gingko_web/live/project_live_test.exs` (new)

**What to build:**

The tabbed project shell. Implements mount, `handle_params/3` (tab whitelist + redirect), PubSub subscription, snapshot hydration, persistent status strip, tab bar, and fan-out `handle_info/2`. **Does not yet render tab content** — renders `<div class="mt-4">Tab not implemented yet</div>` for any active tab. Tab components come in Tasks 4–8.

Shell assigns and responsibilities are fully enumerated in the spec (§Project detail page). Do not read params inside tab renders; shell parses `node`, `filter`, `session_id` from query and passes as part of the `active_params` assign.

Test strategy:
- Unknown `project_id` → 404 via `Ecto.NoResultsError` (assert `assert_error_sent 404`).
- Unknown tab segment → `assert_patch(view, ~p"/projects/#{id}/memories")`.
- Tab switch from `memories` → `graph` uses `push_patch` (process survives, socket `id` unchanged).
- Status strip renders counters + live/degraded/snapshot badge.
- `{:memory_event, %SessionMonitorEvent{type: :session_started, ...}}` updates `counters.active_sessions` without remount.
- Memory refresh debounce: `:changeset_applied` sends `:refresh_memories` after 500ms exactly once even with burst.
- `?node=abc` on graph tab propagates into `active_params`.

**Implementation sketch:**

```elixir
defmodule GingkoWeb.ProjectLive do
  use GingkoWeb, :live_view

  alias Gingko.Memory
  alias Gingko.Memory.ActivityStore
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects

  @tabs ~w(memories search graph health events)
  @default_tab "memories"
  @max_recent_events 100
  @graph_refresh_event_types [
    :changeset_applied, :nodes_deleted, :consolidation_completed,
    :decay_completed, :validation_completed, :session_committed
  ]
  @terminal_states [:idle, :closed, :committed, :failed, :error, :terminated]

  @impl true
  def mount(%{"project_id" => project_id} = params, _session, socket) do
    project = Projects.get_project_by_key!(project_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Gingko.PubSub, Memory.project_monitor_topic(project_id))
      Projects.subscribe_projects()
    end

    snapshot = Memory.project_monitor_snapshot(project_id)
    memories = load_memories(project_id, 10)
    past = load_past_sessions(project_id)
    events = ActivityStore.list(project_id)

    socket =
      socket
      |> assign(
        project_id: project_id,
        project: project,
        counters: normalize_counters(Map.get(snapshot, :counters, %{})),
        quality: Map.get(snapshot, :quality, default_quality()),
        active_sessions: Map.get(snapshot, :active_sessions, []),
        past_sessions: past,
        recent_events: events,
        recent_memories: memories,
        memories_top_k: 10,
        memories_refresh_timer: nil,
        connection_status: if(connected?(socket), do: :live, else: :snapshot),
        rehydrated_at: DateTime.utc_now(),
        active_tab: @default_tab,
        active_params: %{}
      )

    {:ok, apply_tab(socket, params)}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, apply_tab(socket, params)}

  defp apply_tab(socket, %{"tab" => tab} = params) when tab in @tabs do
    assign(socket,
      active_tab: tab,
      active_params: extract_query_params(params)
    )
  end

  defp apply_tab(socket, _params) do
    push_patch(socket, to: ~p"/projects/#{socket.assigns.project_id}/#{@default_tab}")
  end

  defp extract_query_params(params) do
    params
    |> Map.take(["node", "filter", "session_id"])
    |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
  end

  @impl true
  def handle_info({:memory_event, %SessionMonitorEvent{} = event}, socket) do
    if event.project_id == socket.assigns.project_id do
      {:noreply,
       socket
       |> assign(:connection_status, :live)
       |> apply_event(event)
       |> maybe_schedule_memory_refresh(event)
       |> forward_to_active_tab(event)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_memories, socket) do
    {:noreply,
     socket
     |> assign(:memories_refresh_timer, nil)
     |> assign(:recent_memories, load_memories(socket.assigns.project_id, socket.assigns.memories_top_k))}
  end

  def handle_info(:projects_changed, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto w-full max-w-[112rem] px-4 py-6 sm:px-6 lg:px-8">
      <.link navigate={~p"/projects"} class="text-xs text-base-content/70 hover:underline">← Projects</.link>
      <div class="mt-2 rounded-2xl border border-base-300 bg-base-100 p-5">
        <.header>
          {@project.display_name}
          <:subtitle><span class="font-mono text-xs">{@project_id}</span></:subtitle>
        </.header>

        <div class="mt-3 flex flex-wrap items-center gap-3 text-sm">
          <.link
            navigate={~p"/projects/#{@project_id}/events?filter=sessions"}
            class={["inline-flex items-center gap-1", active_class(@counters.active_sessions)]}
          >
            ● {@counters.active_sessions} active
          </.link>
          <span>· {@quality.total_nodes} nodes</span>
          <span :if={@quality.orphan_count > 0} class="text-warning">· {@quality.orphan_count} orphans</span>
          <span :if={@quality.avg_confidence}>· {Float.round(@quality.avg_confidence * 100, 1)}% conf</span>
          <span class={status_badge_class(@connection_status)}>{status_label(@connection_status)}</span>
        </div>

        <nav role="tablist" class="tabs tabs-boxed mt-4 inline-flex">
          <.link
            :for={tab <- @tabs}
            patch={~p"/projects/#{@project_id}/#{tab}"}
            role="tab"
            class={["tab", if(tab == @active_tab, do: "tab-active", else: "")]}
          >
            {tab_label(tab)}
          </.link>
        </nav>
      </div>

      <div class="mt-4">
        <div class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-6 text-sm text-base-content/60">
          Tab "{@active_tab}" not implemented yet.
        </div>
      </div>
    </section>
    """
  end

  # ... apply_event/2, maybe_schedule_memory_refresh/2, forward_to_active_tab/2
  # (lift the logic verbatim from current project_monitor_live.ex:519-542 and
  # ._._.ex:708-718. forward_to_active_tab/2 is a no-op in this task; Tasks 4–8
  # fill it in with per-tab `send_update/2` calls.)
end
```

Router:
```elixir
live "/projects/:project_id/:tab", ProjectLive
# Also accept /projects/:project_id and redirect to :memories — handle via a
# controller redirect or a second live route:
live "/projects/:project_id", ProjectLive  # handle_params redirects to default tab
```

The `@tabs`/`tab_label/1`/`active_class/1`/`status_label/1`/`status_badge_class/1` helpers go in the module. Lift `apply_event`, `update_active_sessions`, `update_quality`, `apply_graph_correction`, `default_quality`, `normalize_counters` verbatim from `lib/gingko_web/live/project_monitor_live.ex` (lines noted in spec).

**Testing:**
```
mix test test/gingko_web/live/project_live_test.exs
```

**Commit:**
```bash
git add lib/gingko_web/live/project_live.ex lib/gingko_web/router.ex test/gingko_web/live/project_live_test.exs
git commit -m "feat: add tabbed project live shell"
```

---

## Task 4: Memories tab

**Files:**
- Create: `lib/gingko_web/live/project_live/memories_tab_component.ex`
- Modify: `lib/gingko_web/live/project_live.ex` — render `MemoriesTabComponent` when `active_tab == "memories"`; handle `{:recent_memories, :change_top_k, k}` from the child
- Test: `test/gingko_web/live/project_live/memories_tab_component_test.exs` (new)

**What to build:**

The default tab. Ports rendering from `lib/gingko_web/live/project_monitor_live/recent_memories_component.ex` (copy + rename module; presentational, receives `memories` + `top_k` as assigns). Shell handles the top_k change message and re-queries via `Memory.latest_memories/1`.

Test strategy:
- Renders empty state with no memories.
- Renders 3 memory rows with correct type badges and content.
- Changing `top_k` select fires `{:recent_memories, :change_top_k, 20}` to the parent (use `render_change/2`).
- After shell handles `change_top_k`, `Memory.latest_memories/1` is called with `top_k: 20` (mock via expectation or shape the test around the component isolated).

**Implementation:**

Copy `RecentMemoriesComponent` into `GingkoWeb.ProjectLive.MemoriesTabComponent` and keep the render/handle_event logic identical. Update shell's render:

```elixir
<.live_component
  :if={@active_tab == "memories"}
  module={GingkoWeb.ProjectLive.MemoriesTabComponent}
  id="memories-tab"
  memories={@recent_memories}
  top_k={@memories_top_k}
/>
```

Shell adds:
```elixir
def handle_info({:recent_memories, :change_top_k, top_k}, socket) do
  {:noreply,
   socket
   |> assign(:memories_top_k, top_k)
   |> assign(:recent_memories, load_memories(socket.assigns.project_id, top_k))}
end
```

Do **not** delete the old `RecentMemoriesComponent` yet; Task 9 cleans up.

**Testing:**
```
mix test test/gingko_web/live/project_live/memories_tab_component_test.exs test/gingko_web/live/project_live_test.exs
```

**Commit:**
```bash
git add lib/gingko_web/live/project_live/memories_tab_component.ex lib/gingko_web/live/project_live.ex test/gingko_web/live/project_live/memories_tab_component_test.exs
git commit -m "feat: memories tab"
```

---

## Task 5: Search tab

**Files:**
- Create: `lib/gingko_web/live/project_live/search_tab_component.ex`
- Modify: `lib/gingko_web/live/project_live.ex` — task ref handling in `handle_info`; render component when active
- Test: `test/gingko_web/live/project_live/search_tab_component_test.exs`

**What to build:**

Textarea + submit. On submit, shell (not the component) spawns `Task.Supervisor.async_nolink(Gingko.TaskSupervisor, fn -> Memory.recall(...) end)` because Task messages target the LiveView process, not LiveComponents. Shell matches `{ref, result}` on the stored ref and `send_update`s the component. `{:DOWN, ref, :process, _, reason}` → component shows error.

Row click on a result patches to `/projects/:id/graph?node=<node_id>`.

Test strategy:
- Form submit triggers `Task.Supervisor` child spawn (assert child count went up via `DynamicSupervisor.count_children/1`).
- Simulated `{ref, {:ok, %{memories: [...]}}}` via `send/2` to the LiveView renders results list.
- Simulated `:DOWN` renders error state.
- Clicking a result row `assert_patch`es to graph tab with `?node=<id>`.
- Late-arriving result after tab switch updates shell cache (next mount sees cached result).

**Implementation outline:**

Component owns local UI state (query text and render of props). Shell owns the task. Reference the current `lib/gingko_web/live/memory_inspector_live.ex` submit_query handler (lines ~72–89) as the starting point — adapt the async flow but route through `send_update/2`.

```elixir
# In ProjectLive (shell) — new event/handle_info clauses
def handle_event("submit_search", %{"query" => query}, socket) when byte_size(query) > 0 do
  task =
    Task.Supervisor.async_nolink(Gingko.TaskSupervisor, fn ->
      Memory.recall(%{project_id: socket.assigns.project_id, query: query})
    end)

  {:noreply, assign(socket, search_task_ref: task.ref, search_text: query, search_status: :searching)}
end

def handle_info({ref, result}, %{assigns: %{search_task_ref: ref}} = socket) do
  Process.demonitor(ref, [:flush])

  socket =
    socket
    |> assign(:search_task_ref, nil)
    |> assign(:search_status, :completed)
    |> assign(:search_result, result)

  send_update(GingkoWeb.ProjectLive.SearchTabComponent,
    id: "search-tab",
    event: {:query_result, result}
  )

  {:noreply, socket}
end

def handle_info({:DOWN, ref, :process, _, reason}, %{assigns: %{search_task_ref: ref}} = socket) do
  send_update(GingkoWeb.ProjectLive.SearchTabComponent,
    id: "search-tab",
    event: {:query_error, reason}
  )
  {:noreply, assign(socket, search_task_ref: nil, search_status: :error)}
end
```

**Testing:**
```
mix test test/gingko_web/live/project_live/search_tab_component_test.exs
```

**Commit:**
```bash
git add lib/gingko_web/live/project_live/search_tab_component.ex lib/gingko_web/live/project_live.ex test/gingko_web/live/project_live/search_tab_component_test.exs
git commit -m "feat: search tab"
```

---

## Task 6: Graph tab (with layout modes)

**Files:**
- Create: `lib/gingko_web/live/project_live/graph_viewport_component.ex` (copy from monitor namespace, module renamed)
- Create: `lib/gingko_web/live/project_live/node_inspector_component.ex` (copy from monitor namespace, module renamed)
- Create: `lib/gingko_web/live/project_live/graph_tab_component.ex` (new)
- Modify: `lib/gingko_web/live/project_live.ex` — render, cluster expand/collapse fan-out
- Test: `test/gingko_web/live/project_live/graph_tab_component_test.exs`

**What to build:**

Graph view with a layout-mode dropdown: **Force**, **Layered**, **Subgoal Tree**, **Provenance**. These map to `Memory.monitor_graph/1` `view:` values (`:project` force/layered, `:focused` for subgoal tree, `:query` for provenance — confirm the exact existing mappings by reading the current `MemoryInspectorLive` that renders Subgoal Tree and Provenance tabs today). Node inspector panel on the right. Cluster expand/collapse events route through the shell (the cluster push_event hook is already there).

Deep-link: `?node=<id>` selects the node on mount.

Test strategy:
- Mount with no `?node` → renders graph with no selection.
- Mount with `?node=abc` → shell's `active_params[:node]` propagates → component pre-selects.
- Layout dropdown change fires `select_layout` → component re-queries `monitor_graph/1` with new `layout_mode`.
- Cluster expand event round-trips through shell (`expand_cluster` handler already exists in current monitor — lift it).

**Implementation pointers:**
- Copy `graph_viewport_component.ex` and `node_inspector_component.ex` with module renames. Do not yet delete originals.
- The layout mode dropdown replaces the current monitor's implicit layout. Subgoal Tree and Provenance logic lives in `Memory.monitor_graph/1` already — the only new thing is wiring both views behind one switcher.
- Move cluster handlers (`expand_cluster`, `collapse_cluster`) from current `ProjectMonitorLive` verbatim into `ProjectLive`.

**Commit:**
```bash
git add lib/gingko_web/live/project_live/graph_viewport_component.ex lib/gingko_web/live/project_live/node_inspector_component.ex lib/gingko_web/live/project_live/graph_tab_component.ex lib/gingko_web/live/project_live.ex test/gingko_web/live/project_live/graph_tab_component_test.exs
git commit -m "feat: graph tab with layout modes"
```

---

## Task 7: Health tab

**Files:**
- Create: `lib/gingko_web/live/project_live/health_tab_component.ex`
- Modify: `lib/gingko_web/live/project_live.ex` — render component; no new shell state
- Test: `test/gingko_web/live/project_live/health_tab_component_test.exs`

**What to build:**

Top row: cards showing `total_nodes`, `total_edges`, `orphan_count`, `avg_confidence`, `last_decay_at`, `last_consolidation_at`, `last_validation_at` from shell's `quality` assign (all seven are already present in `compute_quality/1` output — see `lib/gingko/memory.ex:122-132`).

Below the cards: two columns — Orphans and Low-Confidence — absorbed from `lib/gingko_web/live/memory_inspector_live/orphans_component.ex` and `.../low_confidence_component.ex`. Data source is the existing `Memory.inspector_data/1`. Shell calls `inspector_data/1` **once on first visit to the Health tab** and caches in assigns (`:inspector_node_map`, `:inspector_loaded_at`); subsequent tab visits reuse unless events refreshed it.

Row click on either list: `push_patch(to: ~p"/projects/#{id}/graph?node=#{id}")`.

Test strategy:
- Cards render all seven values, `nil` avg_confidence shows "n/a".
- Lists render orphans and low-confidence nodes from a seeded `inspector_data`.
- Row click patches to graph tab with correct query.
- Lazy load: first mount calls `inspector_data/1` once, second mount (re-entry) does not re-call unless cache was invalidated.

**Commit:**
```bash
git add lib/gingko_web/live/project_live/health_tab_component.ex lib/gingko_web/live/project_live.ex test/gingko_web/live/project_live/health_tab_component_test.exs
git commit -m "feat: health tab"
```

---

## Task 8: Events tab (with sessions filter)

**Files:**
- Create: `lib/gingko_web/live/project_live/events_tab_component.ex`
- Modify: `lib/gingko_web/live/project_live.ex` — render, fan `send_update` on new events
- Test: `test/gingko_web/live/project_live/events_tab_component_test.exs`

**What to build:**

Unified activity feed. Absorbs `lib/gingko_web/live/project_monitor_live/activity_feed_component.ex` row rendering.

Adds:
- Filter bar `[All] [Sessions] [Maintenance] [Recalls]` toggling `filter_mode`.
- With `Sessions` filter: group events by `session_id`; each session row expandable inline to show its lifecycle events (started → steps → committed/expired) and its summary. Replaces today's Active Sessions / Past Sessions / Selection Detail panels.
- Deep-link `?filter=sessions&session_id=<id>` applies on mount.

Test strategy:
- Renders timeline for `filter=all`.
- Filter toggle switches event set.
- With `filter=sessions`: events group under their `session_id`; expanding a session renders its child events.
- Deep-link `?filter=sessions&session_id=abc` pre-applies.
- Shell `send_update` on new `{:memory_event, …}` prepends the row without re-fetch.

**Commit:**
```bash
git add lib/gingko_web/live/project_live/events_tab_component.ex lib/gingko_web/live/project_live.ex test/gingko_web/live/project_live/events_tab_component_test.exs
git commit -m "feat: events tab"
```

---

## Task 9: Teardown

**Files:**
- Delete: `lib/gingko_web/live/memory_inspector_live.ex`
- Delete: `lib/gingko_web/live/memory_inspector_live/` (full directory, 6 components)
- Delete: `lib/gingko_web/live/project_monitor_live.ex`
- Delete: `lib/gingko_web/live/project_monitor_live/` (full directory, 5 components)
- Modify: `lib/gingko_web/router.ex` — remove `/projects/monitor`, `/projects/:project_id/monitor`, `/projects/:project_id/inspector`
- Delete: `test/gingko_web/live/memory_inspector_live_test.exs` (if present)
- Delete: `test/gingko_web/live/project_monitor_live_test.exs` (if present)
- Delete: any inspector-component tests (`test/gingko_web/live/memory_inspector_live/**`)

**What to build:**

Nothing new. This task is exclusively subtractive.

**Pre-flight check:**
```
grep -rn "GingkoWeb.ProjectMonitorLive\|GingkoWeb.MemoryInspectorLive" lib/ test/
```
Expected: zero results outside the files being deleted. If results exist, fix those usages first (they indicate a Task 4–8 incomplete extraction).

**Test strategy:**
- Full suite passes: `mix precommit`.
- `mix test` count is lower than before by the number of deleted test files.
- Visiting `/projects/monitor` → 404 (hardcoded test against this regression).

**Commit:**
```bash
git add -A
git commit -m "refactor: remove monitor and inspector liveviews"
```

---

## Final verification

After Task 9:

```
mix precommit
```

Must pass:
- Compile with `--warnings-as-errors`
- `deps.unlock --unused` finds nothing to prune
- Format clean
- Full test suite green

Then manually smoke-test in a browser:
- `/` redirects to `/projects`
- Card grid shows registered projects with live stats
- Click a card → lands on Memories tab
- Tab navigation works and URL updates
- Header status strip shows live counters while an MCP session is active
- Graph tab Force/Layered/Subgoal Tree/Provenance dropdown renders different layouts
- Search tab returns results and row click jumps to Graph with node pre-selected
- Events tab Sessions filter groups sessions and expand works
- Old `/projects/monitor` and `/projects/:id/inspector` 404

Report blockers as they arise; do not press through failing tests.
