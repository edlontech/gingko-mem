defmodule Gingko.Summaries.DirtyTracker do
  @moduledoc """
  Telemetry handler that enqueues `Gingko.Summaries.ProjectSummaryWorker`
  whenever a memory is appended. The worker's `unique` clause coalesces
  bursty appends into a single debounced regeneration.

  `handle_event/4` wraps its body in a broad `rescue` on purpose: `:telemetry`
  permanently detaches a handler on any uncaught exception, which would
  silently disable summary regeneration until VM restart.
  """

  require Logger

  alias Gingko.Summaries.Config
  alias Gingko.Summaries.ProjectSummaryWorker

  @handler_id {__MODULE__, :mnemosyne_appended}
  @event [:mnemosyne, :memory, :appended]

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @spec handle_event(
          event_name :: [atom()],
          measurements :: map(),
          metadata :: map(),
          config :: term()
        ) :: :ok
  def handle_event(@event, _measurements, %{project_key: project_key}, _config)
      when is_binary(project_key) do
    if Config.enabled?() do
      _ = ProjectSummaryWorker.enqueue(%{project_key: project_key})
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "DirtyTracker handler error: #{Exception.message(error)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end
