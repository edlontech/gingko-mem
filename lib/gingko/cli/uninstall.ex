defmodule Gingko.CLI.Uninstall do
  @moduledoc """
  Full uninstall flow: tear down the service (if installed), remove
  Gingko's config/data directory, remove Burrito's extracted payload
  cache, and print the binary path so the user can delete it.

  All destructive steps are guarded by interactive confirmations.
  """

  alias Gingko.CLI.NodeOps
  alias Gingko.CLI.Paths
  alias Gingko.CLI.Service

  @spec run() :: :ok
  def run do
    Owl.IO.puts(Owl.Data.tag("Gingko uninstall", [:bright, :cyan]))
    Owl.IO.puts("")

    stop_running_node()
    maybe_uninstall_service()
    maybe_remove_gingko_home()
    maybe_remove_burrito_cache()
    announce_binary_path()

    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("Done.", :green))
    :ok
  end

  defp stop_running_node do
    case NodeOps.ping() do
      {:ok, _target} ->
        Owl.IO.puts("Running node detected — stopping...")
        _ = NodeOps.stop()
        :ok

      {:error, :not_running} ->
        :ok
    end
  end

  defp maybe_uninstall_service do
    if Service.installed?() do
      case Service.uninstall() do
        :ok ->
          Owl.IO.puts([
            "Service removed (",
            Owl.Data.tag(Paths.service_unit_path(), :light_black),
            ")"
          ])

        {:error, reason} ->
          Owl.IO.puts(Owl.Data.tag("Failed to remove service: #{inspect(reason)}", :red))
      end
    else
      Owl.IO.puts(Owl.Data.tag("No service unit installed — skipping.", :light_black))
    end
  end

  defp maybe_remove_gingko_home do
    home = Paths.gingko_home()

    if File.exists?(home) do
      prompt = [
        "Remove Gingko data directory ",
        Owl.Data.tag(home, :yellow),
        "? This deletes memory graphs, config, and logs."
      ]

      if Owl.IO.confirm(message: prompt, default: false) do
        File.rm_rf!(home)
        Owl.IO.puts(Owl.Data.tag("Removed #{home}", :green))
      else
        Owl.IO.puts(Owl.Data.tag("Kept #{home}", :light_black))
      end
    end
  end

  defp maybe_remove_burrito_cache do
    with cache_dir when is_binary(cache_dir) <- Paths.burrito_cache_dir(),
         true <- File.exists?(cache_dir) do
      confirm_remove_burrito_cache(cache_dir)
    else
      _ -> :ok
    end
  end

  defp confirm_remove_burrito_cache(cache_dir) do
    prompt = [
      "Remove Burrito payload cache ",
      Owl.Data.tag(cache_dir, :yellow),
      "? A reinstall will re-extract it."
    ]

    if Owl.IO.confirm(message: prompt, default: false) do
      File.rm_rf!(cache_dir)
      Owl.IO.puts(Owl.Data.tag("Removed #{cache_dir}", :green))
    else
      Owl.IO.puts(Owl.Data.tag("Kept #{cache_dir}", :light_black))
    end
  end

  defp announce_binary_path do
    case Paths.binary_path() do
      nil ->
        :ok

      path ->
        Owl.IO.puts("")

        Owl.IO.puts([
          "To remove the binary itself, delete ",
          Owl.Data.tag(path, :yellow)
        ])
    end
  end
end
