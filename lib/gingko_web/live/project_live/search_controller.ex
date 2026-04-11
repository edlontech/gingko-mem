defmodule GingkoWeb.ProjectLive.SearchController do
  @moduledoc """
  Async search task lifecycle extracted from `GingkoWeb.ProjectLive`.

  The shell's `handle_info` clauses delegate into these helpers, which take
  the current socket and return an updated socket. All task-supervision,
  demonitoring, and assign-bookkeeping lives here.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Gingko.Memory

  @spec submit(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def submit(socket, query) do
    if old = socket.assigns.search_task_ref, do: Process.demonitor(old, [:flush])

    project_id = socket.assigns.project_id

    task =
      Task.Supervisor.async_nolink(Gingko.TaskSupervisor, fn ->
        Memory.recall(%{project_id: project_id, query: query})
      end)

    socket
    |> assign(:search_text, query)
    |> assign(:search_status, :searching)
    |> assign(:search_task_ref, task.ref)
  end

  @spec handle_result(Phoenix.LiveView.Socket.t(), reference(), term()) ::
          Phoenix.LiveView.Socket.t()
  def handle_result(socket, ref, result) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, value} ->
        socket
        |> assign(:search_task_ref, nil)
        |> assign(:search_status, :completed)
        |> assign(:search_result, value)

      _ ->
        socket
        |> assign(:search_task_ref, nil)
        |> assign(:search_status, :error)
        |> assign(:search_result, nil)
    end
  end

  @spec handle_down(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_down(socket) do
    socket
    |> assign(:search_task_ref, nil)
    |> assign(:search_status, :error)
    |> assign(:search_result, nil)
  end
end
