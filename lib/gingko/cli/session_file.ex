defmodule Gingko.CLI.SessionFile do
  @moduledoc """
  Tracks the active Gingko session id for a project across hook invocations.

  Each project gets its own pointer file under the system temp directory so
  the SessionStart, append, and SessionEnd hooks can share state without a
  long-lived process.
  """

  @spec path(String.t()) :: Path.t()
  def path(project_id) do
    Path.join(System.tmp_dir!(), "gingko-session-#{project_id}")
  end

  @spec read(String.t()) :: {:ok, String.t()} | :error
  def read(project_id) do
    case File.read(path(project_id)) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> :error
          id -> {:ok, id}
        end

      {:error, _} ->
        :error
    end
  end

  @spec write(String.t(), String.t()) :: :ok | {:error, File.posix()}
  def write(project_id, session_id) do
    File.write(path(project_id), session_id)
  end

  @spec clear(String.t()) :: :ok
  def clear(project_id) do
    case File.rm(path(project_id)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> :ok
    end
  end
end
