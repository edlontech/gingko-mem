defmodule GingkoWeb.ProjectLive.EventsQueryTest do
  use ExUnit.Case, async: true

  alias GingkoWeb.ProjectLive.EventsQuery

  describe "parse_filter_mode/1" do
    test "\"all\" -> :all" do
      assert EventsQuery.parse_filter_mode("all") == :all
    end

    test "\"sessions\" -> :sessions" do
      assert EventsQuery.parse_filter_mode("sessions") == :sessions
    end

    test "\"maintenance\" -> :maintenance" do
      assert EventsQuery.parse_filter_mode("maintenance") == :maintenance
    end

    test "\"recalls\" -> :recalls" do
      assert EventsQuery.parse_filter_mode("recalls") == :recalls
    end

    test "invalid input defaults to :all" do
      assert EventsQuery.parse_filter_mode("bogus") == :all
      assert EventsQuery.parse_filter_mode(nil) == :all
    end
  end

  describe "build_events_query/2" do
    test "(:all, nil) returns empty map" do
      assert EventsQuery.build_events_query(:all, nil) == %{}
    end

    test "(:all, session_id) retains the session_id (current behaviour)" do
      assert EventsQuery.build_events_query(:all, "s-1") == %{"session_id" => "s-1"}
    end

    test "(mode, nil) emits filter only" do
      assert EventsQuery.build_events_query(:sessions, nil) == %{"filter" => "sessions"}
      assert EventsQuery.build_events_query(:maintenance, nil) == %{"filter" => "maintenance"}
      assert EventsQuery.build_events_query(:recalls, nil) == %{"filter" => "recalls"}
    end

    test "(mode, session_id) emits both filter and session_id" do
      assert EventsQuery.build_events_query(:sessions, "s-42") == %{
               "filter" => "sessions",
               "session_id" => "s-42"
             }
    end
  end

  describe "events_path/2" do
    test "without query returns bare events path" do
      assert EventsQuery.events_path("abc", %{}) == "/projects/abc/events"
    end

    test "with filter query returns path with ?filter=..." do
      path = EventsQuery.events_path("abc", %{"filter" => "sessions"})
      assert path =~ "/projects/abc/events"
      assert path =~ "filter=sessions"
    end

    test "with filter + session_id query returns both query params" do
      path =
        EventsQuery.events_path("abc", %{"filter" => "sessions", "session_id" => "s-1"})

      assert path =~ "filter=sessions"
      assert path =~ "session_id=s-1"
    end
  end
end
