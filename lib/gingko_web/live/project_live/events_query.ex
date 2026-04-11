defmodule GingkoWeb.ProjectLive.EventsQuery do
  @moduledoc """
  Pure helpers for building the Events-tab filter query and path.

  No socket, no PubSub — just query-map construction and path formatting.
  """

  use GingkoWeb, :verified_routes

  @type filter_mode :: :all | :sessions | :maintenance | :recalls

  @spec parse_filter_mode(term()) :: filter_mode()
  def parse_filter_mode("all"), do: :all
  def parse_filter_mode("sessions"), do: :sessions
  def parse_filter_mode("maintenance"), do: :maintenance
  def parse_filter_mode("recalls"), do: :recalls
  def parse_filter_mode(_), do: :all

  @spec build_events_query(filter_mode(), String.t() | nil) :: map()
  def build_events_query(:all, nil), do: %{}
  def build_events_query(:all, id), do: %{"session_id" => id}
  def build_events_query(mode, nil), do: %{"filter" => Atom.to_string(mode)}

  def build_events_query(mode, id) do
    %{"filter" => Atom.to_string(mode), "session_id" => id}
  end

  @spec events_path(String.t(), map()) :: String.t()
  def events_path(project_id, query) when map_size(query) == 0 do
    ~p"/projects/#{project_id}/events"
  end

  def events_path(project_id, query) do
    ~p"/projects/#{project_id}/events?#{query}"
  end
end
