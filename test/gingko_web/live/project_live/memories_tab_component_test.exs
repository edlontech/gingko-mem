defmodule GingkoWeb.ProjectLive.MemoriesTabComponentTest do
  use GingkoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GingkoWeb.ProjectLive.MemoriesTabComponent

  describe "empty state" do
    test "renders empty state text when memories list is empty" do
      html =
        render_component(MemoriesTabComponent,
          id: "memories-tab",
          memories: [],
          top_k: 10
        )

      assert html =~ "No recent memories found."
    end
  end

  describe "rendering memories" do
    test "renders semantic, episodic and procedural memories with badges and content" do
      memories = [
        %{
          node: %{type: "semantic", proposition: "Water boils at 100C"},
          metadata: %{confidence: 0.85}
        },
        %{
          node: %{
            type: "episodic",
            observation: "Saw a cat",
            action: "Pet the cat",
            subgoal: nil
          },
          metadata: %{confidence: 0.5}
        },
        %{
          node: %{type: "procedural", instruction: "Tie the shoelaces"},
          metadata: %{}
        }
      ]

      html =
        render_component(MemoriesTabComponent,
          id: "memories-tab",
          memories: memories,
          top_k: 10
        )

      assert html =~ "badge-info"
      assert html =~ "semantic"
      assert html =~ "Water boils at 100C"

      assert html =~ "badge-success"
      assert html =~ "episodic"
      assert html =~ "Observation: Saw a cat"
      assert html =~ "Action: Pet the cat"

      assert html =~ "badge-warning"
      assert html =~ "procedural"
      assert html =~ "Tie the shoelaces"

      assert html =~ "85.0%"
      assert html =~ "50.0%"
    end
  end

  describe "top_k selection" do
    test "selected option reflects current top_k assign" do
      html =
        render_component(MemoriesTabComponent,
          id: "memories-tab",
          memories: [],
          top_k: 20
        )

      assert html =~ ~s(value="20" selected)
      refute html =~ ~s(value="5" selected)
      refute html =~ ~s(value="10" selected)
    end

    test "change_top_k event sends :recent_memories message to parent LiveView" do
      test_pid_str = self() |> :erlang.pid_to_list() |> List.to_string()

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          GingkoWeb.ProjectLive.MemoriesTabComponentTest.Harness,
          session: %{"test_pid" => test_pid_str}
        )

      view
      |> form("form[phx-change=change_top_k]", %{"top_k" => "20"})
      |> render_change()

      assert_receive {:recent_memories, :change_top_k, 20}
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
       |> Phoenix.Component.assign(:top_k, 10)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={GingkoWeb.ProjectLive.MemoriesTabComponent}
          id="memories-tab"
          memories={[]}
          top_k={@top_k}
        />
      </div>
      """
    end

    @impl true
    def handle_info({:recent_memories, :change_top_k, top_k} = msg, socket) do
      send(socket.assigns.test_pid, msg)
      {:noreply, Phoenix.Component.assign(socket, :top_k, top_k)}
    end
  end
end
