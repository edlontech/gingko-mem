defmodule Gingko.CLI.ProjectId do
  @moduledoc """
  Derives the canonical project identifier used by Gingko from the current
  working directory.

  Take the origin remote URL, drop a trailing `.git`, split on `/` or `:`, and join the
  last two segments with `--`. When no git remote is available the result is
  the basename of the working directory.
  """

  @spec detect() :: String.t()
  def detect, do: detect(File.cwd!())

  @spec detect(Path.t()) :: String.t()
  def detect(cwd) do
    case origin_url(cwd) do
      {:ok, url} -> from_remote(url) || Path.basename(cwd)
      :error -> Path.basename(cwd)
    end
  end

  @spec from_remote(String.t()) :: String.t() | nil
  def from_remote(url) do
    url
    |> String.trim()
    |> String.replace_suffix(".git", "")
    |> String.split(["/", ":"], trim: true)
    |> Enum.take(-2)
    |> case do
      [org, repo] -> "#{org}--#{repo}"
      _ -> nil
    end
  end

  defp origin_url(cwd) do
    case System.cmd("git", ["-C", cwd, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> :error
          url -> {:ok, url}
        end

      _ ->
        :error
    end
  rescue
    ErlangError -> :error
  end
end
