defmodule GingkoWeb.ProjectLive.SummariesTabComponentTest do
  use Gingko.DataCase, async: false
  use Oban.Testing, repo: Gingko.Repo

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gingko.Summaries
  alias Gingko.Summaries.ProjectSummaryWorker
  alias GingkoWeb.ProjectLive.SummariesTabComponent

  @endpoint GingkoWeb.Endpoint

  setup do
    Gingko.Repo.query!("DELETE FROM oban_jobs")
    :ok
  end

  describe "empty state" do
    test "renders placeholder text for charter and summary panels when no data exists" do
      html =
        render_component(SummariesTabComponent,
          id: "summaries-tab",
          project_id: "empty-proj"
        )

      assert html =~ "Charter"
      assert html =~ "Summary"

      assert html =~ "No charter set"
      assert html =~ "No summary yet"
    end
  end

  describe "rendering with seeded data" do
    test "renders charter and summary content" do
      project_key = "seeded-proj"

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "charter",
          content: "Charter prose here."
        })

      {:ok, _} =
        Summaries.upsert_section(%{
          project_key: project_key,
          kind: "summary",
          content: "## Current focus\n\nSummary body."
        })

      html =
        render_component(SummariesTabComponent,
          id: "summaries-tab",
          project_id: project_key
        )

      assert html =~ "Charter prose here."
      assert html =~ "Current focus"
      assert html =~ "Summary body."
    end
  end

  describe "save_charter event" do
    test "persists new charter content" do
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

    test "does not overwrite a locked charter and surfaces a flash" do
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

  describe "refresh_summary event" do
    test "enqueues a ProjectSummaryWorker job" do
      project_key = "refresh-proj"

      {:ok, view, _html} =
        live_isolated(
          build_conn(),
          __MODULE__.Harness,
          session: %{"project_id" => project_key}
        )

      view
      |> element("button", "Regenerate")
      |> render_click()

      assert [_job] =
               all_enqueued(
                 worker: ProjectSummaryWorker,
                 args: %{project_key: project_key}
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
