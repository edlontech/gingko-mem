defmodule GingkoWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use GingkoWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil, doc: "current page title"

  attr :update_status, :any,
    default: nil,
    doc:
      "result from `Gingko.UpdateChecker.status/0`; auto-injected by the LiveView on_mount hook"

  attr :update_apply, :any,
    default: :idle,
    doc: "current applier stage from `Gingko.UpdateApplier`"

  attr :update_supervised, :boolean,
    default: false,
    doc: "true when a service manager is wired up so an automatic restart will happen"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="gingko-shell min-h-screen bg-base-200 text-base-content">
      <div class="gingko-shell__aurora" aria-hidden="true"></div>
      <div class="relative flex min-h-screen">
        <aside class="gingko-sidebar hidden shrink-0 lg:flex lg:w-72 lg:flex-col">
          <div class="gingko-sidebar__panel">
            <a href={~p"/"} class="flex items-center gap-3">
              <span class="flex size-11 items-center justify-center rounded-2xl bg-primary text-primary-content shadow-lg">
                <img src={~p"/images/logo.png"} width="24" />
              </span>
              <div>
                <p class="font-serif text-2xl tracking-[0.08em]">Gingko</p>
                <p class="text-xs uppercase tracking-[0.32em] text-base-content/55">Workspace</p>
              </div>
            </a>

            <div class="mt-10 space-y-2">
              <.shell_nav_link
                navigate={~p"/projects"}
                icon="hero-command-line"
                label="Projects"
              />
              <.shell_nav_link navigate={~p"/cost"} icon="hero-banknotes" label="Costs" />
              <.shell_nav_link href="/oban" icon="hero-queue-list" label="Oban" />
              <.shell_nav_link navigate={~p"/setup"} icon="hero-cog-6-tooth" label="Setup" />
            </div>

            <div class="gingko-sidebar__card mt-8">
              <p class="text-xs uppercase tracking-[0.28em] text-base-content/50">Focus</p>
              <p class="mt-3 text-lg font-semibold leading-7">
                Keep project memory, setup, and live activity in one calm workspace.
              </p>
              <p class="mt-3 text-sm leading-6 text-base-content/70">
                The shell stays global so setup and monitoring feel like parts of the same tool.
              </p>
            </div>
          </div>
        </aside>

        <div class="flex min-h-screen min-w-0 flex-1 flex-col">
          <header class="gingko-topbar">
            <div class="flex min-w-0 items-center gap-4">
              <a href={~p"/"} class="flex items-center gap-3 lg:hidden">
                <span class="flex size-10 items-center justify-center rounded-2xl bg-primary text-primary-content shadow-lg">
                  <img src={~p"/images/logo.png"} width="20" />
                </span>
                <div>
                  <p class="font-serif text-xl tracking-[0.08em]">Gingko</p>
                  <p class="text-[0.65rem] uppercase tracking-[0.24em] text-base-content/55">
                    Workspace
                  </p>
                </div>
              </a>

              <div class="min-w-0">
                <p class="text-xs uppercase tracking-[0.28em] text-base-content/45">Workspace</p>
                <h1 class="truncate text-xl font-semibold">{@page_title || "Overview"}</h1>
              </div>
            </div>

            <div class="flex items-center gap-3">
              <.update_badge
                status={@update_status}
                apply_state={@update_apply}
                supervised={@update_supervised}
              />
              <div class="rounded-full border border-base-300/80 bg-base-100/85 px-2 py-2 shadow-sm backdrop-blur">
                <span class="sr-only">System Theme</span>
                <.theme_toggle />
              </div>
            </div>
          </header>

          <main class="flex-1 px-4 pb-6 pt-4 sm:px-6 lg:px-8 lg:pb-8">
            <div class="mx-auto w-full max-w-7xl">
              {render_slot(@inner_block)}
            </div>
          </main>
        </div>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :status, :any, required: true
  attr :apply_state, :any, default: :idle
  attr :supervised, :boolean, default: false

  defp update_badge(%{status: {:update_available, info}} = assigns) do
    assigns =
      assigns
      |> assign(:info, info)
      |> assign(:in_progress, in_progress?(assigns.apply_state))

    ~H"""
    <details class="dropdown dropdown-end relative">
      <summary class={[
        "inline-flex cursor-pointer list-none items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-semibold shadow-sm backdrop-blur transition [&::-webkit-details-marker]:hidden",
        badge_classes(@apply_state)
      ]}>
        <.badge_icon stage={@apply_state} />
        <span>{badge_label(@apply_state, @info.latest)}</span>
      </summary>
      <div class="dropdown-content z-30 mt-2 w-80 rounded-2xl border border-base-300 bg-base-100 p-4 text-sm shadow-xl">
        <p class="font-semibold">Gingko {@info.latest} is available</p>
        <p class="mt-1 text-xs text-base-content/60">You are on {@info.current}.</p>

        <.apply_panel
          state={@apply_state}
          supervised={@supervised}
          info={@info}
          in_progress={@in_progress}
        />

        <a
          href={@info.html_url}
          target="_blank"
          rel="noopener"
          class="mt-3 inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline"
        >
          Release notes <.icon name="hero-arrow-top-right-on-square-micro" class="size-3" />
        </a>
      </div>
    </details>
    """
  end

  defp update_badge(%{status: :up_to_date} = assigns) do
    assigns = assign(assigns, :version, Gingko.UpdateChecker.current_version())

    ~H"""
    <button
      type="button"
      class="hidden cursor-pointer items-center gap-2 rounded-full border border-base-300/80 bg-base-100/80 px-3 py-1.5 text-xs font-medium text-base-content/65 shadow-sm backdrop-blur transition hover:text-base-content md:inline-flex"
      title="Check for updates"
      phx-click="gingko:check_updates"
    >
      <.icon name="hero-check-circle-micro" class="size-4 text-success" />
      <span>Up to date{version_suffix(@version)}</span>
    </button>
    """
  end

  defp update_badge(%{status: :unknown} = assigns) do
    assigns = assign(assigns, :version, Gingko.UpdateChecker.current_version())

    ~H"""
    <button
      type="button"
      class="hidden cursor-pointer items-center gap-2 rounded-full border border-base-300/80 bg-base-100/80 px-3 py-1.5 text-xs font-medium text-base-content/60 shadow-sm backdrop-blur transition hover:text-base-content md:inline-flex"
      title="Check for updates"
      phx-click="gingko:check_updates"
    >
      <.icon name="hero-arrow-up-circle-micro" class="size-4" />
      <span>Gingko{version_suffix(@version)}</span>
    </button>
    """
  end

  defp update_badge(assigns), do: ~H""

  defp version_suffix(nil), do: ""
  defp version_suffix(version), do: " · v#{version}"

  attr :stage, :any, required: true

  defp badge_icon(%{stage: stage} = assigns)
       when stage in [:starting, :downloading, :swapping, :restarting] do
    ~H"""
    <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
    """
  end

  defp badge_icon(%{stage: {:error, _}} = assigns) do
    ~H"""
    <.icon name="hero-exclamation-triangle-micro" class="size-4" />
    """
  end

  defp badge_icon(assigns) do
    ~H"""
    <.icon name="hero-arrow-up-circle-micro" class="size-4" />
    """
  end

  attr :state, :any, required: true
  attr :supervised, :boolean, required: true
  attr :info, :map, required: true
  attr :in_progress, :boolean, required: true

  defp apply_panel(%{state: {:done, version}} = assigns) do
    assigns = assign(assigns, :version, version)

    ~H"""
    <div class="mt-3 rounded-lg border border-success/30 bg-success/10 px-3 py-2 text-xs text-success-content">
      Restarting Gingko {@version}. The page will reconnect automatically.
    </div>
    """
  end

  defp apply_panel(%{state: {:error, reason}} = assigns) do
    assigns = assign(assigns, :reason, reason)

    ~H"""
    <div class="mt-3 rounded-lg border border-error/40 bg-error/10 px-3 py-2 text-xs text-error">
      Update failed: {format_apply_error(@reason)}
    </div>
    <div class="mt-3 flex items-center justify-between gap-2">
      <button
        type="button"
        class="inline-flex items-center gap-1 rounded-full border border-primary/40 bg-primary px-3 py-1.5 text-xs font-semibold text-primary-content shadow-sm hover:opacity-90"
        phx-click="gingko:start_update"
      >
        Retry
      </button>
      <.cli_fallback />
    </div>
    """
  end

  defp apply_panel(%{in_progress: true} = assigns) do
    ~H"""
    <div class="mt-3 flex items-center gap-2 rounded-lg border border-base-300 bg-base-200 px-3 py-2 text-xs text-base-content/80">
      <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
      <span>{stage_message(@state)}</span>
    </div>
    """
  end

  defp apply_panel(%{supervised: true} = assigns) do
    ~H"""
    <button
      type="button"
      class="mt-3 inline-flex w-full items-center justify-center gap-2 rounded-full bg-primary px-3 py-2 text-xs font-semibold text-primary-content shadow-sm hover:opacity-90"
      phx-click="gingko:start_update"
    >
      <.icon name="hero-arrow-up-circle-micro" class="size-4" /> Update now
    </button>
    <p class="mt-2 text-[0.65rem] uppercase tracking-wider text-base-content/50">
      Or run from a terminal:
    </p>
    <.cli_fallback />
    """
  end

  defp apply_panel(assigns) do
    ~H"""
    <p class="mt-3 text-xs text-base-content/70">
      No service manager detected. Run this command to upgrade:
    </p>
    <.cli_fallback />
    """
  end

  defp cli_fallback(assigns) do
    ~H"""
    <div class="mt-1 flex items-center gap-2 rounded-lg border border-base-300 bg-base-200 px-3 py-2 font-mono text-xs">
      <code id="gingko-update-cmd" class="flex-1 truncate">gingko update</code>
      <button
        type="button"
        class="rounded-md border border-base-300 bg-base-100 px-2 py-1 text-[0.65rem] uppercase tracking-wider text-base-content/70 hover:bg-base-200"
        phx-click={
          JS.dispatch("phx:copy", to: "#gingko-update-cmd")
          |> JS.transition({"transition-all", "opacity-100", "opacity-50"}, time: 250)
        }
        aria-label="Copy command"
      >
        Copy
      </button>
    </div>
    """
  end

  defp in_progress?(stage) when stage in [:starting, :downloading, :swapping, :restarting],
    do: true

  defp in_progress?(_), do: false

  defp badge_classes(stage) when stage in [:starting, :downloading, :swapping, :restarting],
    do: "border-warning/40 bg-warning/10 text-warning"

  defp badge_classes({:error, _}), do: "border-error/40 bg-error/10 text-error"
  defp badge_classes(_), do: "border-primary/40 bg-primary/10 text-primary hover:bg-primary/20"

  defp badge_label(:starting, _), do: "Starting…"
  defp badge_label(:downloading, _), do: "Downloading…"
  defp badge_label(:swapping, _), do: "Installing…"
  defp badge_label(:restarting, _), do: "Restarting…"
  defp badge_label({:done, v}, _), do: "Restarting #{v}…"
  defp badge_label({:error, _}, _), do: "Update failed"
  defp badge_label(_, latest), do: "Update #{latest}"

  defp stage_message(:starting), do: "Starting…"
  defp stage_message(:downloading), do: "Downloading the new release…"
  defp stage_message(:swapping), do: "Installing the new binary…"
  defp stage_message(:restarting), do: "Restarting the service…"
  defp stage_message(_), do: "Working…"

  defp format_apply_error(:binary_path_unknown),
    do: "could not find the running Gingko binary."

  defp format_apply_error(:no_releases_published), do: "no release published yet."
  defp format_apply_error({:asset_missing, name}), do: "asset #{name} not found."
  defp format_apply_error({:download_status, status}), do: "download HTTP #{status}."
  defp format_apply_error({:download, reason}), do: "download error (#{inspect(reason)})."
  defp format_apply_error({:github_status, status}), do: "GitHub HTTP #{status}."
  defp format_apply_error({:github, reason}), do: "GitHub error (#{inspect(reason)})."
  defp format_apply_error({:unsupported_target, os, arch}), do: "no asset for #{os}/#{arch}."
  defp format_apply_error(:spawn_failed), do: "could not start the updater task."
  defp format_apply_error(other), do: inspect(other)

  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp shell_nav_link(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <.link href={@href} class="gingko-sidebar__link">
      <span class="flex size-10 items-center justify-center rounded-2xl bg-base-100/80 text-base-content/70">
        <.icon name={@icon} class="size-5" />
      </span>
      <span class="text-sm font-medium">{@label}</span>
    </.link>
    """
  end

  defp shell_nav_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="gingko-sidebar__link">
      <span class="flex size-10 items-center justify-center rounded-2xl bg-base-100/80 text-base-content/70">
        <.icon name={@icon} class="size-5" />
      </span>
      <span class="text-sm font-medium">{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center rounded-full border border-base-300 bg-base-200/80 p-0.5">
      <div class="absolute left-0 h-full w-1/3 rounded-full border border-base-200 bg-base-100 brightness-105 transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3" />

      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System Theme"
        title="System Theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light Theme"
        title="Light Theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark Theme"
        title="Dark Theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
