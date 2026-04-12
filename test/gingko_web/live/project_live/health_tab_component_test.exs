defmodule GingkoWeb.ProjectLive.HealthTabComponentTest do
  use GingkoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Gingko.Memory.ProjectSnapshot
  alias GingkoWeb.ProjectLive.HealthTabComponent
  alias Mnemosyne.Graph.Edge
  alias Mnemosyne.Graph.Node.Semantic

  describe "quality cards" do
    test "renders all 7 quality metrics with values" do
      quality = %{
        total_nodes: 42,
        total_edges: 7,
        orphan_count: 3,
        avg_confidence: 0.912,
        last_decay_at: ~U[2026-04-10 12:00:00Z],
        last_consolidation_at: ~U[2026-04-11 13:00:00Z],
        last_validation_at: ~U[2026-04-12 14:00:00Z]
      }

      html =
        render_component(HealthTabComponent,
          id: "health-tab",
          project_id: "p-1",
          quality: quality,
          node_map: %{}
        )

      assert html =~ "Total Nodes"
      assert html =~ "42"
      assert html =~ "Total Edges"
      assert html =~ "7"
      assert html =~ "Orphans"
      assert html =~ "3"
      assert html =~ "Avg Confidence"
      assert html =~ "91.2%"
      assert html =~ "Last Decay"
      assert html =~ "2026-04-10"
      assert html =~ "Last Consolidation"
      assert html =~ "2026-04-11"
      assert html =~ "Last Validation"
      assert html =~ "2026-04-12"
    end

    test "nil avg_confidence renders n/a" do
      quality = %{
        total_nodes: 0,
        total_edges: 0,
        orphan_count: 0,
        avg_confidence: nil,
        last_decay_at: nil,
        last_consolidation_at: nil,
        last_validation_at: nil
      }

      html =
        render_component(HealthTabComponent,
          id: "health-tab",
          project_id: "p-1",
          quality: quality,
          node_map: %{}
        )

      assert html =~ "n/a"
      refute html =~ "%"
    end
  end

  describe "orphans section" do
    test "renders orphan nodes from the node_map prop" do
      orphan = %Semantic{
        id: "orphan-1",
        proposition: "orphaned fact",
        confidence: 0.9,
        links: Edge.empty_links()
      }

      linked =
        %Semantic{
          id: "linked-1",
          proposition: "linked fact",
          confidence: 0.9,
          links: Edge.empty_links()
        }
        |> put_in([Access.key!(:links), :supports], MapSet.new(["orphan-1"]))

      node_map = %{"orphan-1" => orphan, "linked-1" => linked}

      html =
        render_component(HealthTabComponent,
          id: "health-tab",
          project_id: "p-1",
          quality: ProjectSnapshot.default_quality(),
          node_map: node_map
        )

      assert html =~ "orphaned fact"
      refute html =~ "linked fact"
      assert html =~ "1 orphaned nodes"
    end

    test "orphan row has a patch link to the graph tab with node query" do
      orphan = %Semantic{
        id: "orphan-xyz",
        proposition: "orphaned fact",
        confidence: 0.9,
        links: Edge.empty_links()
      }

      html =
        render_component(HealthTabComponent,
          id: "health-tab",
          project_id: "my-project",
          quality: ProjectSnapshot.default_quality(),
          node_map: %{"orphan-xyz" => orphan}
        )

      assert html =~ ~s|href="/projects/my-project/graph?node=orphan-xyz"|
      assert html =~ ~s|data-phx-link="patch"|
    end

    test "shows empty state when there are no orphans" do
      html =
        render_component(HealthTabComponent,
          id: "health-tab",
          project_id: "p-1",
          quality: ProjectSnapshot.default_quality(),
          node_map: %{}
        )

      assert html =~ "No orphaned nodes"
    end
  end

  describe "low-confidence section" do
    test "renders nodes below the default threshold with slider" do
      linked = %{Edge.empty_links() | membership: MapSet.new(["other"])}

      node_map = %{
        "sem1" => %Semantic{
          id: "sem1",
          proposition: "shaky fact",
          confidence: 0.3,
          links: linked
        },
        "sem2" => %Semantic{
          id: "sem2",
          proposition: "strong fact",
          confidence: 0.95,
          links: linked
        }
      }

      html =
        render_component(HealthTabComponent,
          id: "health-tab",
          project_id: "p-1",
          quality: ProjectSnapshot.default_quality(),
          node_map: node_map
        )

      assert html =~ "shaky fact"
      refute html =~ "strong fact"
      assert html =~ ~s|type="range"|
      assert html =~ "Confidence threshold"
    end

    test "threshold change re-filters the list via render_change" do
      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          __MODULE__.Harness
        )

      initial = render(view)
      assert initial =~ "weak fact"
      refute initial =~ "medium fact"

      view
      |> form(~s|form[phx-change="set_threshold"]|, %{"value" => "0.8"})
      |> render_change()

      after_change = render(view)
      assert after_change =~ "weak fact"
      assert after_change =~ "medium fact"
    end

    test "low-confidence row has a patch link to the graph tab" do
      node_map = %{
        "low-1" => %Semantic{
          id: "low-1",
          proposition: "unsure",
          confidence: 0.1,
          links: Edge.empty_links()
        }
      }

      html =
        render_component(HealthTabComponent,
          id: "health-tab",
          project_id: "proj-xyz",
          quality: ProjectSnapshot.default_quality(),
          node_map: node_map
        )

      assert html =~ ~s|href="/projects/proj-xyz/graph?node=low-1"|
      assert html =~ ~s|data-phx-link="patch"|
    end
  end

  defmodule Harness do
    use GingkoWeb, :live_view

    alias Gingko.Memory.ProjectSnapshot
    alias Mnemosyne.Graph.Edge
    alias Mnemosyne.Graph.Node.Semantic

    @impl true
    def mount(_params, _session, socket) do
      linked = %{Edge.empty_links() | membership: MapSet.new(["other"])}

      node_map = %{
        "weak" => %Semantic{
          id: "weak",
          proposition: "weak fact",
          confidence: 0.2,
          links: linked
        },
        "medium" => %Semantic{
          id: "medium",
          proposition: "medium fact",
          confidence: 0.7,
          links: linked
        }
      }

      {:ok, Phoenix.Component.assign(socket, :node_map, node_map)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={GingkoWeb.ProjectLive.HealthTabComponent}
          id="health-tab"
          project_id="p-1"
          quality={ProjectSnapshot.default_quality()}
          node_map={@node_map}
        />
      </div>
      """
    end
  end
end
