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
                <img src={~p"/images/logo.svg"} width="24" />
              </span>
              <div>
                <p class="font-serif text-2xl tracking-[0.08em]">Gingko</p>
                <p class="text-xs uppercase tracking-[0.32em] text-base-content/55">Workspace</p>
              </div>
            </a>

            <div class="mt-10 space-y-2">
              <.shell_nav_link navigate={~p"/setup"} icon="hero-cog-6-tooth" label="Setup" />
              <.shell_nav_link
                navigate={~p"/projects"}
                icon="hero-command-line"
                label="Projects"
              />
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
                  <img src={~p"/images/logo.svg"} width="20" />
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
              <div class="hidden rounded-full border border-base-300/80 bg-base-100/80 px-3 py-2 text-xs font-medium text-base-content/60 backdrop-blur md:block">
                Local-first memory tooling
              </div>
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

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

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
