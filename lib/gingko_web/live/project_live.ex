defmodule GingkoWeb.ProjectLive do
  @moduledoc """
  Tabbed project detail shell.

  Owns project-wide assigns (counters, quality, sessions, recent events) and
  routes the five sibling tabs via `push_patch`. Tab content is rendered by
  dedicated `Phoenix.LiveComponent`s wired up in later tasks; today the shell
  renders a placeholder for the active tab.
  """

  use GingkoWeb, :live_view

  alias Gingko.Memory
  alias Gingko.Memory.ActivityStore
  alias Gingko.Memory.ProjectSnapshot
  alias Gingko.Memory.SessionMonitorEvent
  alias Gingko.Projects
  alias GingkoWeb.ProjectLive.EventsQuery
  alias GingkoWeb.ProjectLive.GraphView
  alias GingkoWeb.ProjectLive.SearchController

  @tabs ~w(memories search graph health events summaries overlays)
  @default_tab "memories"
  @allowed_filter_modes [:all, :sessions, :maintenance, :recalls]
  @graph_refresh_event_types [
    :changeset_applied,
    :nodes_deleted,
    :consolidation_completed,
    :decay_completed,
    :validation_completed,
    :session_committed
  ]
  @inspector_invalidation_events [
    :changeset_applied,
    :nodes_deleted,
    :consolidation_completed,
    :decay_completed,
    :validation_completed
  ]
  @allowed_query_keys ["node", "filter", "session_id"]

  @impl true
  def mount(%{"project_id" => project_id} = _params, _session, socket) do
    project = Projects.get_project_by_key!(project_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Gingko.PubSub, Memory.project_monitor_topic(project_id))
      Projects.subscribe_projects()
    end

    snapshot = Memory.project_monitor_snapshot(project_id)
    past = load_past_sessions(project_id)
    events = ActivityStore.list(project_id)
    memories = load_memories(project_id, 10)

    socket =
      socket
      |> assign(:tabs, @tabs)
      |> assign(:project_id, project_id)
      |> assign(:project, project)
      |> assign(:counters, ProjectSnapshot.normalize_counters(Map.get(snapshot, :counters, %{})))
      |> assign(:quality, Map.get(snapshot, :quality, ProjectSnapshot.default_quality()))
      |> assign(:active_sessions, Map.get(snapshot, :active_sessions, []))
      |> assign(:past_sessions, past)
      |> assign(:recent_events, events)
      |> assign(:recent_memories, memories)
      |> assign(:memories_top_k, 10)
      |> assign(:memories_refresh_timer, nil)
      |> assign(:connection_status, initial_connection_status(socket, snapshot))
      |> assign(:rehydrated_at, DateTime.utc_now())
      |> assign(:active_tab, @default_tab)
      |> assign(:active_params, %{})
      |> assign(:search_text, "")
      |> assign(:search_status, :idle)
      |> assign(:search_result, nil)
      |> assign(:search_task_ref, nil)
      |> assign(:graph_layout_mode, :force)
      |> assign(:graph_view, GraphView.empty_graph_view(:project))
      |> assign(:selected_node_id, nil)
      |> assign(:expanded_node_ids, MapSet.new())
      |> assign(:expanded_cluster_id, nil)
      |> assign(:inspector_node_map, %{})
      |> assign(:inspector_loaded_at, nil)
      |> assign(:events_filter_mode, :all)
      |> assign(:events_session_filter, nil)
      |> assign(:events_expanded_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"tab" => tab} = params, _uri, socket) when tab in @tabs do
    active_params = extract_query_params(params)

    socket =
      socket
      |> assign(:active_tab, tab)
      |> assign(:active_params, active_params)
      |> GraphView.maybe_apply_graph_deep_link(tab, active_params)
      |> maybe_apply_events_deep_link(tab, active_params)
      |> GraphView.maybe_refresh_graph_view(tab)
      |> maybe_load_inspector_data(tab)

    {:noreply, socket}
  end

  def handle_params(%{"project_id" => project_id} = _params, _uri, socket) do
    {:noreply, push_patch(socket, to: ~p"/projects/#{project_id}/#{@default_tab}")}
  end

  @impl true
  def handle_event("select_graph_node", %{"id" => node_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_node_id, node_id)
     |> GraphView.apply_node_selection(node_id)}
  end

  def handle_event("expand_graph_node", %{"id" => node_id}, socket) do
    expanded = MapSet.put(socket.assigns.expanded_node_ids, node_id)

    {:noreply,
     socket
     |> assign(:expanded_node_ids, expanded)
     |> GraphView.refresh_graph_view()}
  end

  def handle_event("expand_cluster", %{"cluster_id" => cluster_id}, socket) do
    socket =
      if old = socket.assigns.expanded_cluster_id do
        push_event(socket, "cluster_collapsed", %{cluster_id: old})
      else
        socket
      end

    case Memory.expand_cluster(%{
           project_id: socket.assigns.project_id,
           cluster_id: cluster_id
         }) do
      {:ok, expansion} ->
        {:noreply,
         socket
         |> assign(:expanded_cluster_id, cluster_id)
         |> push_event("cluster_expanded", expansion)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Cluster no longer exists. Refreshing graph.")
         |> assign(:expanded_cluster_id, nil)
         |> GraphView.refresh_graph_view()}
    end
  end

  def handle_event("collapse_cluster", %{"cluster_id" => cluster_id}, socket) do
    {:noreply,
     socket
     |> assign(:expanded_cluster_id, nil)
     |> push_event("cluster_collapsed", %{cluster_id: cluster_id})}
  end

  @impl true
  def handle_info({:memory_event, %SessionMonitorEvent{} = event}, socket) do
    handle_project_event(event, socket)
  end

  def handle_info({:memory_event, _other}, socket) do
    {:noreply, assign(socket, :connection_status, :degraded)}
  end

  def handle_info(:refresh_memories, socket) do
    {:noreply,
     socket
     |> assign(:memories_refresh_timer, nil)
     |> assign(
       :recent_memories,
       load_memories(socket.assigns.project_id, socket.assigns.memories_top_k)
     )}
  end

  def handle_info(:projects_changed, socket), do: {:noreply, socket}

  def handle_info({:graph, :select_layout, layout}, socket) do
    {:noreply,
     socket
     |> assign(:graph_layout_mode, layout)
     |> GraphView.refresh_graph_view()}
  end

  def handle_info({:events, :set_filter, mode}, socket) when mode in @allowed_filter_modes do
    project_id = socket.assigns.project_id
    session_filter = socket.assigns.events_session_filter

    query = EventsQuery.build_events_query(mode, session_filter)
    path = EventsQuery.events_path(project_id, query)

    {:noreply,
     socket
     |> assign(:events_filter_mode, mode)
     |> push_patch(to: path)}
  end

  def handle_info({:events, :toggle_event, key}, socket) do
    current = socket.assigns.events_expanded_id
    next = if current == key, do: nil, else: key
    {:noreply, assign(socket, :events_expanded_id, next)}
  end

  def handle_info({:events, :filter_session, session_id}, socket) do
    project_id = socket.assigns.project_id
    query = EventsQuery.build_events_query(:sessions, session_id)
    path = EventsQuery.events_path(project_id, query)

    {:noreply,
     socket
     |> assign(:events_filter_mode, :sessions)
     |> assign(:events_session_filter, session_id)
     |> push_patch(to: path)}
  end

  def handle_info({:recent_memories, :change_top_k, top_k}, socket) do
    {:noreply,
     socket
     |> assign(:memories_top_k, top_k)
     |> assign(:recent_memories, load_memories(socket.assigns.project_id, top_k))}
  end

  def handle_info({:search, :submit, query}, socket) when is_binary(query) do
    case String.trim(query) do
      "" -> {:noreply, socket}
      trimmed -> {:noreply, SearchController.submit(socket, trimmed)}
    end
  end

  def handle_info({ref, result}, %{assigns: %{search_task_ref: ref}} = socket)
      when is_reference(ref) do
    {:noreply, SearchController.handle_result(socket, ref, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{search_task_ref: ref}} = socket
      )
      when is_reference(ref) do
    {:noreply, SearchController.handle_down(socket)}
  end

  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={assigns[:page_title]}>
      <section class="mx-auto w-full max-w-[112rem] px-4 py-6 sm:px-6 lg:px-8">
        <.link navigate={~p"/projects"} class="text-xs text-base-content/70 hover:underline">
          ← Projects
        </.link>

        <div class="mt-2 rounded-2xl border border-base-300 bg-base-100 p-5">
          <.header>
            {@project.display_name}
            <:subtitle><span class="font-mono text-xs">{@project_id}</span></:subtitle>
          </.header>

          <div class="mt-3 flex flex-wrap items-center gap-3 text-sm">
            <.link
              patch={~p"/projects/#{@project_id}/events?filter=sessions"}
              class={["inline-flex items-center gap-1", active_class(@counters.active_sessions)]}
            >
              ● {@counters.active_sessions} active
            </.link>
            <span>· {@quality.total_nodes} nodes</span>
            <span :if={@quality.orphan_count > 0} class="text-warning">
              · {@quality.orphan_count} orphans
            </span>
            <span :if={@quality.avg_confidence}>
              · {Float.round(@quality.avg_confidence * 100, 1)}% conf
            </span>
            <span class={status_badge_class(@connection_status)}>
              {status_label(@connection_status)}
            </span>
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
          {render_tab(assigns)}
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp render_tab(%{active_tab: "memories"} = assigns) do
    ~H"""
    <.live_component
      module={GingkoWeb.ProjectLive.MemoriesTabComponent}
      id="memories-tab"
      memories={@recent_memories}
      top_k={@memories_top_k}
    />
    """
  end

  defp render_tab(%{active_tab: "search"} = assigns) do
    ~H"""
    <.live_component
      module={GingkoWeb.ProjectLive.SearchTabComponent}
      id="search-tab"
      project_id={@project_id}
      query_text={@search_text}
      query_status={@search_status}
      query_result={@search_result}
    />
    """
  end

  defp render_tab(%{active_tab: "graph"} = assigns) do
    ~H"""
    <.live_component
      module={GingkoWeb.ProjectLive.GraphTabComponent}
      id="graph-tab"
      project_id={@project_id}
      graph={@graph_view}
      layout_mode={@graph_layout_mode}
      selected_node_id={@selected_node_id}
      expanded_cluster_id={@expanded_cluster_id}
    />
    """
  end

  defp render_tab(%{active_tab: "health"} = assigns) do
    ~H"""
    <.live_component
      module={GingkoWeb.ProjectLive.HealthTabComponent}
      id="health-tab"
      project_id={@project_id}
      quality={@quality}
      node_map={@inspector_node_map}
    />
    """
  end

  defp render_tab(%{active_tab: "events"} = assigns) do
    ~H"""
    <.live_component
      module={GingkoWeb.ProjectLive.EventsTabComponent}
      id="events-tab"
      project_id={@project_id}
      events={@recent_events}
      active_sessions={@active_sessions}
      past_sessions={@past_sessions}
      filter_mode={@events_filter_mode}
      session_id_filter={@events_session_filter}
      expanded_event_id={@events_expanded_id}
    />
    """
  end

  defp render_tab(%{active_tab: "summaries"} = assigns) do
    ~H"""
    <.live_component
      module={GingkoWeb.ProjectLive.SummariesTabComponent}
      id="summaries-tab"
      project_id={@project_id}
    />
    """
  end

  defp render_tab(%{active_tab: "overlays"} = assigns) do
    ~H"""
    <.live_component
      module={GingkoWeb.ProjectLive.OverlaysTabComponent}
      id="overlays-tab"
      project_id={@project_id}
    />
    """
  end

  defp render_tab(assigns) do
    ~H"""
    <div class="rounded-2xl border border-dashed border-base-300 bg-base-100 p-6 text-sm text-base-content/60">
      Tab "{@active_tab}" not implemented yet.
    </div>
    """
  end

  defp handle_project_event(event, socket) do
    if event.project_id == socket.assigns.project_id do
      updated =
        socket
        |> assign(:connection_status, :live)
        |> apply_snapshot_event(event)
        |> maybe_refresh_past_sessions(event)
        |> maybe_invalidate_inspector_cache(event)
        |> maybe_schedule_memory_refresh(event)

      {:noreply, updated}
    else
      {:noreply, socket}
    end
  end

  defp maybe_invalidate_inspector_cache(socket, %SessionMonitorEvent{type: type})
       when type in @inspector_invalidation_events do
    socket
    |> assign(:inspector_loaded_at, nil)
    |> maybe_load_inspector_data(socket.assigns.active_tab)
  end

  defp maybe_invalidate_inspector_cache(socket, _event), do: socket

  defp apply_snapshot_event(socket, event) do
    snapshot = %{
      counters: socket.assigns.counters,
      quality: socket.assigns.quality,
      active_sessions: socket.assigns.active_sessions,
      past_sessions: socket.assigns.past_sessions,
      recent_events: socket.assigns.recent_events
    }

    updated = ProjectSnapshot.apply_event(snapshot, event)

    assign(socket,
      counters: updated.counters,
      quality: updated.quality,
      active_sessions: updated.active_sessions,
      recent_events: updated.recent_events
    )
  end

  defp maybe_refresh_past_sessions(socket, %SessionMonitorEvent{type: type})
       when type in [:session_committed, :session_expired] do
    if is_binary(socket.assigns.project_id) do
      assign(socket, :past_sessions, load_past_sessions(socket.assigns.project_id))
    else
      socket
    end
  end

  defp maybe_refresh_past_sessions(socket, _event), do: socket

  defp extract_query_params(params) do
    params
    |> Map.take(@allowed_query_keys)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp maybe_schedule_memory_refresh(socket, %SessionMonitorEvent{type: type})
       when type in @graph_refresh_event_types do
    if timer = socket.assigns.memories_refresh_timer do
      Process.cancel_timer(timer)
    end

    timer = Process.send_after(self(), :refresh_memories, 500)
    assign(socket, :memories_refresh_timer, timer)
  end

  defp maybe_schedule_memory_refresh(socket, _event), do: socket

  defp load_memories(project_id, top_k) do
    case Memory.latest_memories(%{project_id: project_id, top_k: top_k}) do
      {:ok, %{memories: memories}} -> memories
      _ -> []
    end
  end

  defp load_past_sessions(project_id) do
    Projects.list_sessions(project_id, status: "finished")
  rescue
    Ecto.NoResultsError -> []
  end

  defp initial_connection_status(_socket, %{degraded: true}), do: :degraded

  defp initial_connection_status(socket, _snapshot) do
    if connected?(socket), do: :live, else: :snapshot
  end

  defp status_label(:live), do: "live"
  defp status_label(:degraded), do: "degraded"
  defp status_label(:snapshot), do: "snapshot"

  defp status_badge_class(:live),
    do: "rounded-full bg-emerald-100 px-3 py-1 text-emerald-900"

  defp status_badge_class(:degraded),
    do: "rounded-full bg-amber-100 px-3 py-1 text-amber-900"

  defp status_badge_class(:snapshot),
    do: "rounded-full bg-slate-100 px-3 py-1 text-slate-800"

  defp active_class(n) when n > 0, do: "text-success"
  defp active_class(_), do: "text-base-content/40"

  defp tab_label("memories"), do: "Memories"
  defp tab_label("search"), do: "Search"
  defp tab_label("graph"), do: "Graph"
  defp tab_label("health"), do: "Health"
  defp tab_label("events"), do: "Events"
  defp tab_label("summaries"), do: "Summaries"
  defp tab_label("overlays"), do: "Overlays"

  defp maybe_apply_events_deep_link(socket, "events", params) do
    mode = EventsQuery.parse_filter_mode(Map.get(params, :filter))
    session_filter = Map.get(params, :session_id)

    socket
    |> assign(:events_filter_mode, mode)
    |> assign(:events_session_filter, session_filter)
  end

  defp maybe_apply_events_deep_link(socket, _tab, _params), do: socket

  defp maybe_load_inspector_data(socket, "health") do
    if socket.assigns.inspector_loaded_at do
      socket
    else
      case Memory.inspector_data(socket.assigns.project_id) do
        {:ok, node_map} ->
          socket
          |> assign(:inspector_node_map, node_map)
          |> assign(:inspector_loaded_at, DateTime.utc_now())

        {:error, _} ->
          socket
      end
    end
  end

  defp maybe_load_inspector_data(socket, _tab), do: socket
end
