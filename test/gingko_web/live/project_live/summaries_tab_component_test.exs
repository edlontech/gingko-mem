defmodule GingkoWeb.ProjectLive.SummariesTabComponentTest do
  use Gingko.DataCase, async: false
  use Oban.Testing, repo: Gingko.Repo

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.PrincipalStateWorker
  alias GingkoWeb.ProjectLive.SummariesTabComponent

  @endpoint GingkoWeb.Endpoint

  setup do
    Gingko.Repo.query!("DELETE FROM oban_jobs")
    :ok
  end

  describe "empty state" do
    test "renders placeholder text for every panel when no data exists" do
      html =
        render_component(SummariesTabComponent,
          id: "summaries-tab",
          project_id: "empty-proj"
        )

      assert html =~ "Playbook"
      assert html =~ "Charter"
      assert html =~ "State"
      assert html =~ "Clusters"

      assert html =~ "No playbook seeded"
      assert html =~ "No charter set"
      assert html =~ "No state summary"
      assert html =~ "No cluster summaries"
    end
  end

  describe "rendering with seeded data" do
    test "renders playbook, charter, state content, and cluster rows" do
      project_key = "seeded-proj"

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "playbook",
          content: "# The Playbook Heading\n\nbody body body"
        })

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "charter",
          content: "Charter prose here."
        })

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "state",
          content: "## Current state\n\nState body."
        })

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: project_key,
          tag_node_id: "tag-auth",
          tag_label: "Auth",
          slug: "auth",
          headline: "Auth cluster headline",
          memory_count: 12,
          last_generated_at: ~U[2026-04-20 09:00:00Z],
          dirty: false
        })

      html =
        render_component(SummariesTabComponent,
          id: "summaries-tab",
          project_id: project_key
        )

      assert html =~ "The Playbook Heading"
      assert html =~ "body body body"

      assert html =~ "Charter prose here."

      assert html =~ "Current state"
      assert html =~ "State body."

      assert html =~ "auth"
      assert html =~ "Auth cluster headline"
      assert html =~ "12"
    end

    test "cluster row marked dirty shows dirty indicator" do
      project_key = "dirty-proj"

      {:ok, _} =
        Summaries.upsert_cluster(%{
          project_key: project_key,
          tag_node_id: "tag-graph",
          tag_label: "Graph",
          slug: "graph",
          headline: "Graph headline",
          memory_count: 3,
          dirty: true,
          dirty_since: ~U[2026-04-20 12:00:00Z]
        })

      html =
        render_component(SummariesTabComponent,
          id: "summaries-tab",
          project_id: project_key
        )

      assert html =~ "graph"
      assert html =~ "dirty"
    end
  end

  describe "save_charter event" do
    test "persists new charter content and shows flash" do
      project_key = "charter-proj"

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          __MODULE__.Harness,
          session: %{"project_id" => project_key}
        )

      view
      |> element("#summaries-charter-form")
      |> render_submit(%{"content" => "brand new charter"})

      section = Summaries.get_section(project_key, "charter")
      assert section.content == "brand new charter"
    end

    test "does not overwrite a locked charter and surfaces the locked-error flash" do
      project_key = "locked-proj"

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "charter",
          content: "the original",
          locked: true
        })

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          __MODULE__.Harness,
          session: %{"project_id" => project_key}
        )

      view
      |> element("#summaries-charter-form")
      |> render_submit(%{"content" => "attempted overwrite"})

      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "charter is locked and cannot be overwritten"

      section = Summaries.get_section(project_key, "charter")
      assert section.content == "the original"
    end
  end

  describe "refresh_principal_memory events" do
    test "state scope enqueues a PrincipalStateWorker job" do
      project_key = "refresh-state-proj"

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          __MODULE__.Harness,
          session: %{"project_id" => project_key}
        )

      view
      |> element(~s|button[phx-value-scope="state"]|)
      |> render_click()

      assert [_job] =
               all_enqueued(
                 worker: PrincipalStateWorker,
                 args: %{project_key: project_key}
               )
    end

    test "cluster scope enqueues a ClusterWorker job with the matched tag_node_id" do
      project_key = "refresh-cluster-proj"

      {:ok, _cluster} =
        Summaries.upsert_cluster(%{
          project_key: project_key,
          tag_node_id: "tag-xyz",
          tag_label: "XYZ",
          slug: "xyz",
          memory_count: 2
        })

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          __MODULE__.Harness,
          session: %{"project_id" => project_key}
        )

      view
      |> element(~s|button[phx-value-scope="cluster"][phx-value-slug="xyz"]|)
      |> render_click()

      assert [_job] =
               all_enqueued(
                 worker: ClusterWorker,
                 args: %{project_key: project_key, tag_node_id: "tag-xyz"}
               )
    end
  end

  defmodule Harness do
    use GingkoWeb, :live_view

    @impl true
    def mount(_params, %{"project_id" => project_id}, socket) do
      {:ok, Phoenix.Component.assign(socket, :project_id, project_id)}
    end

    @impl true
    def handle_info({:put_flash, kind, message}, socket) do
      {:noreply, Phoenix.LiveView.put_flash(socket, kind, message)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <Layouts.flash_group flash={@flash} />
        <.live_component
          module={GingkoWeb.ProjectLive.SummariesTabComponent}
          id="summaries-tab"
          project_id={@project_id}
        />
      </div>
      """
    end
  end
end
