defmodule GingkoWeb.ProjectLive.SearchTabComponentTest do
  use GingkoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GingkoWeb.ProjectLive.SearchTabComponent

  describe "idle state" do
    test "renders textarea, submit button, and the idle hint" do
      html =
        render_component(SearchTabComponent,
          id: "search-tab",
          project_id: "p-1",
          query_text: "",
          query_status: :idle,
          query_result: nil
        )

      assert html =~ ~s(name="query")
      assert html =~ "Search"
      assert html =~ "Enter a natural language query"
    end
  end

  describe "searching state" do
    test "shows a loading indicator and disables the submit button" do
      html =
        render_component(SearchTabComponent,
          id: "search-tab",
          project_id: "p-1",
          query_text: "hello",
          query_status: :searching,
          query_result: nil
        )

      assert html =~ "loading loading-spinner"
      assert html =~ ~s(disabled)
      assert html =~ "hello"
    end
  end

  describe "completed state" do
    test "renders result rows with memory type sections and touched-node links" do
      result = %{
        project_id: "p-1",
        query: "what about cats",
        session_id: nil,
        memory: %{
          semantic: "Cats purr when content.",
          episodic: "Observed: cat purring.",
          procedural: ""
        },
        touched_node_ids: ["node-1", "node-2"]
      }

      html =
        render_component(SearchTabComponent,
          id: "search-tab",
          project_id: "p-1",
          query_text: "what about cats",
          query_status: :completed,
          query_result: result
        )

      assert html =~ "Cats purr when content."
      assert html =~ "Observed: cat purring."
      refute html =~ ~s(badge-warning">Procedural)
      assert html =~ "node-1"
      assert html =~ "node-2"
      assert html =~ ~s(href="/projects/p-1/graph?node=node-1")
      assert html =~ ~s(href="/projects/p-1/graph?node=node-2")
    end

    test "empty touched nodes shows a no-results hint" do
      result = %{
        project_id: "p-1",
        query: "nothing",
        session_id: nil,
        memory: %{semantic: nil, episodic: nil, procedural: nil},
        touched_node_ids: []
      }

      html =
        render_component(SearchTabComponent,
          id: "search-tab",
          project_id: "p-1",
          query_text: "nothing",
          query_status: :completed,
          query_result: result
        )

      assert html =~ "No matches"
    end
  end

  describe "error state" do
    test "renders an error message" do
      html =
        render_component(SearchTabComponent,
          id: "search-tab",
          project_id: "p-1",
          query_text: "boom",
          query_status: :error,
          query_result: nil
        )

      assert html =~ "Search failed"
    end
  end

  describe "form submit" do
    test "submit event dispatches {:search, :submit, query} to parent LiveView" do
      test_pid_str = self() |> :erlang.pid_to_list() |> List.to_string()

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          GingkoWeb.ProjectLive.SearchTabComponentTest.Harness,
          session: %{"test_pid" => test_pid_str}
        )

      view
      |> form("form[phx-submit=submit_search]", %{"query" => "my query"})
      |> render_submit()

      assert_receive {:search, :submit, "my query"}
    end

    test "blank submit does not dispatch" do
      test_pid_str = self() |> :erlang.pid_to_list() |> List.to_string()

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          GingkoWeb.ProjectLive.SearchTabComponentTest.Harness,
          session: %{"test_pid" => test_pid_str}
        )

      view
      |> form("form[phx-submit=submit_search]", %{"query" => "   "})
      |> render_submit()

      refute_receive {:search, :submit, _}, 100
    end
  end

  defmodule Harness do
    use GingkoWeb, :live_view

    @impl true
    def mount(_params, %{"test_pid" => test_pid_str}, socket) do
      test_pid = test_pid_str |> String.to_charlist() |> :erlang.list_to_pid()

      {:ok,
       socket
       |> Phoenix.Component.assign(:test_pid, test_pid)
       |> Phoenix.Component.assign(:query_text, "")
       |> Phoenix.Component.assign(:query_status, :idle)
       |> Phoenix.Component.assign(:query_result, nil)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={GingkoWeb.ProjectLive.SearchTabComponent}
          id="search-tab"
          project_id="p-1"
          query_text={@query_text}
          query_status={@query_status}
          query_result={@query_result}
        />
      </div>
      """
    end

    @impl true
    def handle_info({:search, :submit, _query} = msg, socket) do
      send(socket.assigns.test_pid, msg)
      {:noreply, socket}
    end
  end
end
