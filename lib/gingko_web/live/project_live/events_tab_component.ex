defmodule GingkoWeb.ProjectLive.EventsTabComponent do
  @moduledoc """
  Events tab for `GingkoWeb.ProjectLive`.

  Unified activity timeline. Owns the filter bar, groups sessions when the
  Sessions filter is active, and supports inline expand/collapse of rows. All
  mutating interactions dispatch `{:events, action, payload}` messages back to
  the shell via `send(self(), ...)`. Rendering is fully prop-driven: the shell
  updates its `recent_events` assign, LiveView change tracking re-renders the
  component.
  """

  use GingkoWeb, :live_component

  alias Gingko.Memory.SessionMonitorEvent

  @maintenance_types [
    :decay_completed,
    :consolidation_completed,
    :validation_completed,
    :nodes_deleted
  ]
  @recall_types [:recall_executed, :recall_failed]
  @session_lifecycle_types [
    :session_started,
    :step_appended,
    :session_committed,
    :session_expired,
    :session_state_changed
  ]
  @read_types [:recall_executed]
  @error_types [:recall_failed]

  @filter_modes [:all, :sessions, :maintenance, :recalls]

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filter_modes, @filter_modes)

    ~H"""
    <section class="rounded-2xl border border-base-300 bg-base-100 p-4">
      <div
        role="group"
        aria-label="Event filter"
        class="flex flex-wrap items-center gap-2 border-b border-base-200 pb-3"
      >
        <button
          :for={mode <- @filter_modes}
          phx-click="set_filter"
          phx-value-mode={Atom.to_string(mode)}
          phx-target={@myself}
          aria-pressed={to_string(mode == @filter_mode)}
          class={["btn btn-sm", filter_button_class(mode, @filter_mode)]}
        >
          {filter_label(mode)}
        </button>
      </div>

      <div class="mt-3">
        {render_body(assigns)}
      </div>
    </section>
    """
  end

  defp render_body(%{filter_mode: :sessions} = assigns) do
    rows = session_rows(assigns.events, assigns.active_sessions, assigns.past_sessions)
    expanded = expanded_session_id(assigns)
    assigns = assigns |> assign(:rows, rows) |> assign(:expanded, expanded)

    ~H"""
    <div :if={Enum.empty?(@rows)} class="text-sm text-base-content/70">
      No sessions yet.
    </div>

    <div :if={not Enum.empty?(@rows)} class="space-y-2">
      <div
        :for={row <- @rows}
        class={[
          "rounded-lg border-l-4 border border-base-300 bg-base-100",
          session_border_class(row.state)
        ]}
      >
        <button
          phx-click="filter_session"
          phx-value-session_id={row.session_id}
          phx-target={@myself}
          class="w-full p-3 text-left hover:bg-base-200 transition"
        >
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2">
              <span class="rounded px-1.5 py-0.5 text-[10px] font-bold uppercase bg-base-200 text-base-content/80">
                session
              </span>
              <span class="font-mono text-xs">{row.session_id}</span>
              <span class="rounded-full border border-base-300 px-2 py-0.5 text-[10px] uppercase tracking-wide">
                {row.state}
              </span>
            </div>
            <span class="text-xs text-base-content/70">
              {format_timestamp(row.latest_activity_at)}
            </span>
          </div>
          <div :if={row.summary_line} class="mt-1 text-xs text-base-content/70 truncate">
            {row.summary_line}
          </div>
        </button>

        <div :if={@expanded == row.session_id} class="border-t border-base-300 px-3 py-2 text-xs">
          <dl :if={map_size(row.summary) > 0} class="space-y-1 mb-2">
            <div :for={{k, v} <- row.summary} class="flex gap-2">
              <dt class="font-semibold text-base-content/70 min-w-[6rem]">{k}:</dt>
              <dd class="font-mono break-all">{format_value(v)}</dd>
            </div>
          </dl>

          <p class="font-semibold text-base-content/70 mt-1 mb-1">Lifecycle:</p>
          <div :if={Enum.empty?(row.lifecycle_events)} class="text-base-content/50 italic">
            No lifecycle events recorded.
          </div>
          <ul :if={not Enum.empty?(row.lifecycle_events)} class="space-y-1">
            <li :for={ev <- row.lifecycle_events} class="flex items-center justify-between gap-2">
              <span class="font-mono">{ev.type}</span>
              <span class="text-base-content/60">{event_description(ev)}</span>
              <span class="text-base-content/40">{format_timestamp(ev.timestamp)}</span>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp render_body(assigns) do
    filtered = filter_events(assigns.events, assigns.filter_mode)
    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <div :if={Enum.empty?(@filtered)} class="text-sm text-base-content/70">
      No events to show.
    </div>

    <div :if={not Enum.empty?(@filtered)} class="space-y-2">
      <div :for={event <- @filtered}>
        <% key = SessionMonitorEvent.event_key(event) %>
        <% type = card_type(event) %>
        <% expanded = @expanded_event_id == key %>
        <div class={[
          "rounded-lg border-l-4 border border-base-300 bg-base-100",
          card_border_class(type)
        ]}>
          <button
            phx-click="toggle_event"
            phx-value-key={key}
            phx-target={@myself}
            class="w-full p-3 text-left hover:bg-base-200 transition"
          >
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <span class={[
                  "rounded px-1.5 py-0.5 text-[10px] font-bold uppercase",
                  card_badge_class(type)
                ]}>
                  {type}
                </span>
                <span class="font-mono text-xs">{event_type_label(event)}</span>
              </div>
              <span class="text-xs text-base-content/70">
                {format_timestamp(event.timestamp)}
              </span>
            </div>
            <div class="mt-1 text-xs text-base-content/70 truncate">
              {event_description(event)}
            </div>
          </button>

          <div :if={expanded} class="border-t border-base-300 px-3 py-2 text-xs">
            <dl :if={map_size(event.summary) > 0} class="space-y-1">
              <div :for={{k, v} <- event.summary} class="flex gap-2">
                <dt class="font-semibold text-base-content/70 min-w-[6rem]">{k}:</dt>
                <dd class="font-mono break-all">{format_value(v)}</dd>
              </div>
            </dl>

            <div :if={event.node_ids != []} class="mt-2">
              <p class="font-semibold text-base-content/70 mb-1">Nodes:</p>
              <div class="flex flex-wrap gap-1">
                <span :for={node_id <- event.node_ids} class="font-mono text-[11px] text-primary">
                  {truncate(node_id, 16)}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("set_filter", %{"mode" => mode}, socket) do
    case parse_filter_mode(mode) do
      {:ok, atom} ->
        send(self(), {:events, :set_filter, atom})
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_event", %{"key" => key}, socket) do
    send(self(), {:events, :toggle_event, key})
    {:noreply, socket}
  end

  def handle_event("filter_session", %{"session_id" => id}, socket) do
    send(self(), {:events, :filter_session, id})
    {:noreply, socket}
  end

  defp parse_filter_mode("all"), do: {:ok, :all}
  defp parse_filter_mode("sessions"), do: {:ok, :sessions}
  defp parse_filter_mode("maintenance"), do: {:ok, :maintenance}
  defp parse_filter_mode("recalls"), do: {:ok, :recalls}
  defp parse_filter_mode(_), do: :error

  defp filter_events(events, :all), do: events

  defp filter_events(events, :maintenance) do
    Enum.filter(events, fn ev -> ev.type in @maintenance_types end)
  end

  defp filter_events(events, :recalls) do
    Enum.filter(events, fn ev -> ev.type in @recall_types end)
  end

  defp filter_events(events, _), do: events

  defp session_rows(events, active_sessions, past_sessions) do
    active_rows = Enum.map(active_sessions, &active_session_row(&1, events))
    past_rows = Enum.map(past_sessions, &past_session_row(&1, events))

    seen = MapSet.new(active_rows, & &1.session_id)

    past_rows
    |> Enum.reject(fn row -> MapSet.member?(seen, row.session_id) end)
    |> Kernel.++(active_rows)
    |> Enum.sort_by(& &1.latest_activity_at, {:desc, DateTime})
  end

  defp active_session_row(s, events) do
    summary = s.summary

    %{
      session_id: s.session_id,
      state: s.state,
      latest_activity_at: s.latest_activity_at,
      summary: summary,
      summary_line: summary_line(summary),
      lifecycle_events: events_for_session(events, s.session_id)
    }
  end

  defp past_session_row(s, events) do
    summary = %{goal: s.goal, node_count: s.node_count}

    %{
      session_id: s.session_id,
      state: past_session_state(s.status),
      latest_activity_at: s.finished_at || s.updated_at,
      summary: summary,
      summary_line: summary_line(summary),
      lifecycle_events: events_for_session(events, s.session_id)
    }
  end

  defp past_session_state("finished"), do: :finished
  defp past_session_state("abandoned"), do: :abandoned
  defp past_session_state("active"), do: :active
  defp past_session_state(_), do: :finished

  defp events_for_session(events, session_id) do
    Enum.filter(events, fn ev ->
      ev.session_id == session_id and ev.type in @session_lifecycle_types
    end)
  end

  defp summary_line(%{goal: goal}) when is_binary(goal) and goal != "", do: truncate(goal, 80)
  defp summary_line(_), do: nil

  defp expanded_session_id(%{session_id_filter: id}) when is_binary(id), do: id

  defp expanded_session_id(%{expanded_event_id: "session:" <> id}), do: id

  defp expanded_session_id(_), do: nil

  defp filter_button_class(mode, mode), do: "btn-primary btn-active"
  defp filter_button_class(_, _), do: "btn-ghost"

  defp filter_label(:all), do: "All"
  defp filter_label(:sessions), do: "Sessions"
  defp filter_label(:maintenance), do: "Maintenance"
  defp filter_label(:recalls), do: "Recalls"

  defp card_type(%SessionMonitorEvent{type: type}) when type in @read_types, do: :READ
  defp card_type(%SessionMonitorEvent{type: type}) when type in @error_types, do: :ERROR
  defp card_type(_event), do: :WRITE

  defp card_border_class(:READ), do: "border-l-blue-500"
  defp card_border_class(:WRITE), do: "border-l-green-500"
  defp card_border_class(:ERROR), do: "border-l-red-500"

  defp card_badge_class(:READ), do: "bg-blue-100 text-blue-800"
  defp card_badge_class(:WRITE), do: "bg-green-100 text-green-800"
  defp card_badge_class(:ERROR), do: "bg-red-100 text-red-800"

  defp session_border_class(:collecting), do: "border-l-amber-500"
  defp session_border_class(:active), do: "border-l-amber-500"
  defp session_border_class(:finished), do: "border-l-emerald-500"
  defp session_border_class(:committed), do: "border-l-emerald-500"
  defp session_border_class(:expired), do: "border-l-slate-400"
  defp session_border_class(:abandoned), do: "border-l-slate-400"
  defp session_border_class(_), do: "border-l-slate-400"

  defp event_type_label(%SessionMonitorEvent{type: type}), do: Atom.to_string(type)

  defp event_description(%SessionMonitorEvent{type: :recall_executed, summary: s}) do
    query = Map.get(s, :query_snippet, "?")
    count = Map.get(s, :result_count, "?")
    mode = Map.get(s, :search_mode, "unknown")
    ms = Map.get(s, :duration_ms)
    duration = if ms, do: ", #{ms}ms", else: ""
    "'#{truncate(query, 30)}' -> #{count} results (#{mode}#{duration})"
  end

  defp event_description(%SessionMonitorEvent{type: :recall_failed, summary: s}) do
    query = Map.get(s, :query_snippet, "?")
    reason = Map.get(s, :reason, "unknown")
    "'#{truncate(query, 30)}' -- #{reason}"
  end

  defp event_description(%SessionMonitorEvent{type: :step_appended, summary: s}) do
    idx = Map.get(s, :step_index, 0)
    subgoal = Map.get(s, :subgoal)
    if subgoal, do: "step #{idx} | #{truncate(subgoal, 40)}", else: "step #{idx}"
  end

  defp event_description(%SessionMonitorEvent{type: :session_committed, summary: s}) do
    count = Map.get(s, :node_count, 0)
    "#{count} nodes committed"
  end

  defp event_description(%SessionMonitorEvent{type: :changeset_applied, summary: s}) do
    nodes = Map.get(s, :node_count, 0)
    links = Map.get(s, :link_count, 0)
    "#{nodes} nodes, #{links} links"
  end

  defp event_description(%SessionMonitorEvent{type: type}) do
    type |> Atom.to_string() |> String.replace("_", " ")
  end

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  defp format_value(v) when is_number(v), do: to_string(v)
  defp format_value(v) when is_list(v), do: Enum.join(v, ", ")
  defp format_value(v), do: inspect(v, pretty: true, limit: 5)

  defp format_timestamp(nil), do: ""
  defp format_timestamp(%DateTime{} = ts), do: Calendar.strftime(ts, "%H:%M:%S")
  defp format_timestamp(other), do: to_string(other)

  defp truncate(nil, _max), do: ""
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) <> "..."
end
