defmodule Gingko.CLI.Dispatcher do
  @moduledoc """
  Routes CLI subcommands received via `:init.get_plain_arguments/0`.

  Called at the very top of `Gingko.Application.start/2`. Returns
  `:boot` when the process should continue starting the server
  supervisor, or halts the VM when a CLI subcommand has been handled.
  """

  alias Gingko.CLI.Hook
  alias Gingko.CLI.Memory
  alias Gingko.CLI.NodeOps
  alias Gingko.CLI.Paths
  alias Gingko.CLI.Remote
  alias Gingko.CLI.Service
  alias Gingko.CLI.Uninstall
  alias Gingko.CLI.Update

  @type result :: :boot | no_return()

  @spec maybe_dispatch([charlist()] | [String.t()]) :: result()
  def maybe_dispatch(argv) do
    case normalize(argv) do
      [] ->
        :boot

      ["start" | _] ->
        :boot

      [cmd | rest] ->
        dispatch(cmd, rest)
        System.halt(0)
    end
  end

  defp normalize(argv) do
    Enum.map(argv, fn
      arg when is_list(arg) -> List.to_string(arg)
      arg when is_binary(arg) -> arg
    end)
  end

  defp dispatch("help", _), do: print_help()
  defp dispatch("--help", _), do: print_help()
  defp dispatch("-h", _), do: print_help()
  defp dispatch("version", _), do: print_version()
  defp dispatch("status", _), do: print_status()
  defp dispatch("stop", _), do: run_stop()
  defp dispatch("pid", _), do: print_pid()
  defp dispatch("remote", _), do: run_remote()
  defp dispatch("rpc", []), do: error("rpc requires an expression argument")
  defp dispatch("rpc", [expr | _]), do: run_rpc(expr)
  defp dispatch("install", _), do: run_service_install()
  defp dispatch("uninstall", _), do: Uninstall.run()
  defp dispatch("update", args), do: run_update(args)

  defp dispatch("service", []), do: print_service_help()
  defp dispatch("service", ["install" | _]), do: run_service_install()
  defp dispatch("service", ["uninstall" | _]), do: run_service_uninstall()
  defp dispatch("service", ["start" | _]), do: run_service_start()
  defp dispatch("service", ["stop" | _]), do: run_service_stop()
  defp dispatch("service", ["status" | _]), do: run_service_status()
  defp dispatch("service", ["installed" | _]), do: run_service_installed()
  defp dispatch("service", ["logs" | rest]), do: run_service_logs(rest)
  defp dispatch("service", [cmd | _]), do: error("unknown service subcommand: #{cmd}")

  defp dispatch("memory", []), do: Memory.print_help()
  defp dispatch("memory", [cmd | args]), do: System.halt(Memory.run(cmd, args))

  defp dispatch("hook", []), do: print_hook_help()
  defp dispatch("hook", ["session-start" | _]), do: System.halt(Hook.SessionStart.run())
  defp dispatch("hook", ["session-stop" | _]), do: System.halt(Hook.SessionStop.run())
  defp dispatch("hook", ["session-end" | _]), do: System.halt(Hook.SessionEnd.run())
  defp dispatch("hook", [cmd | _]), do: error("unknown hook subcommand: #{cmd}")

  defp dispatch(cmd, _) do
    error("unknown command: #{cmd}")
    print_help()
  end

  defp print_help do
    Owl.IO.puts(Owl.Data.tag("Gingko — graph-based memory engine", [:bright, :cyan]))
    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("Usage:", :bright))
    Owl.IO.puts("  gingko <command> [args]")
    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("Node control:", :bright))
    Owl.IO.puts("  start              Run in foreground (default)")
    Owl.IO.puts("  status             Show whether Gingko is running")
    Owl.IO.puts("  stop               Stop the running node")
    Owl.IO.puts("  pid                Print the OS PID of the running node")
    Owl.IO.puts("  remote             Print an erl -remsh command for a remote IEx")
    Owl.IO.puts(~s|  rpc "<expr>"       Eval Elixir in the running node|)
    Owl.IO.puts("  version            Print version")
    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("Service (user-level):", :bright))
    Owl.IO.puts("  install            Register to start at login (alias for 'service install')")
    Owl.IO.puts("  uninstall          Full wipe: service + data + cache")
    Owl.IO.puts("  update [--force]   Download the latest release and swap the binary in place")
    Owl.IO.puts("  service install    Install launchd/systemd unit")
    Owl.IO.puts("  service uninstall  Remove launchd/systemd unit")
    Owl.IO.puts("  service start      Start via service manager")
    Owl.IO.puts("  service stop       Stop via service manager")
    Owl.IO.puts("  service status     Show service manager status")
    Owl.IO.puts("  service installed  Exit 0 if the service unit is installed")
    Owl.IO.puts("  service logs [-f]  Show or tail service logs")
    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("Memory (project-scoped):", :bright))
    Owl.IO.puts("  memory <subcommand> See `gingko memory help` for the full list")
    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("Claude Code hooks:", :bright))
    Owl.IO.puts("  hook session-start  Emit SessionStart additionalContext")
    Owl.IO.puts("  hook session-stop   Summarize transcript tail")
    Owl.IO.puts("  hook session-end    Commit and clear the active session")
    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("Other:", :bright))
    Owl.IO.puts("  maintenance        Burrito payload cache maintenance")
    Owl.IO.puts("  help               Show this help")
  end

  defp print_service_help do
    Owl.IO.puts("Usage: gingko service {install|uninstall|start|stop|status|installed|logs}")
  end

  defp print_hook_help do
    Owl.IO.puts("Usage: gingko hook {session-start|session-stop|session-end}")
  end

  defp print_version do
    vsn = Application.spec(:gingko, :vsn) |> to_string()
    Owl.IO.puts("gingko #{vsn}")
  end

  defp print_status do
    case NodeOps.status() do
      {:ok, %{node: node, pid: pid, uptime_ms: uptime}} ->
        Owl.IO.puts([
          Owl.Data.tag("● running", :green),
          " — ",
          Owl.Data.tag(Atom.to_string(node), :bright)
        ])

        Owl.IO.puts("  pid:     #{pid}")
        Owl.IO.puts("  uptime:  #{format_uptime(uptime)}")

      {:error, :not_running} ->
        Owl.IO.puts([Owl.Data.tag("○ not running", :light_black)])
    end
  end

  defp print_pid do
    case NodeOps.pid() do
      {:ok, pid} -> Owl.IO.puts(pid)
      {:error, :not_running} -> error("not running")
    end
  end

  defp run_stop do
    case NodeOps.stop() do
      :ok -> Owl.IO.puts(Owl.Data.tag("Stopped", :green))
      {:error, :not_running} -> Owl.IO.puts(Owl.Data.tag("Not running", :light_black))
    end
  end

  defp run_rpc(expr) do
    case NodeOps.rpc(expr) do
      {:ok, value} -> IO.puts(inspect(value, pretty: true))
      {:error, :not_running} -> error("not running")
      {:error, reason} -> error(inspect(reason))
    end
  end

  defp run_remote do
    case Remote.run() do
      :ok -> :ok
      {:error, :not_running} -> error("not running")
      {:error, :erl_not_found} -> error("could not locate erl in $RELEASE_ROOT/erts-*/bin")
    end
  end

  defp run_update(args) do
    case Update.run(args) do
      :ok -> :ok
      {:error, _reason} -> System.halt(1)
    end
  end

  defp run_service_install do
    case Service.install() do
      :ok ->
        Owl.IO.puts(Owl.Data.tag("Service installed.", :green))

        Owl.IO.puts([
          "Unit: ",
          Owl.Data.tag(Paths.service_unit_path(), :light_black)
        ])

        if Paths.os() == :linux and not Service.linger_enabled?() do
          Owl.IO.puts("")

          Owl.IO.puts(
            Owl.Data.tag(
              "Note: to keep the service running after you log out, run:",
              :yellow
            )
          )

          Owl.IO.puts(Owl.Data.tag("  sudo loginctl enable-linger $USER", :bright))
        end

      {:error, reason} ->
        error("install failed: #{inspect(reason)}")
    end
  end

  defp run_service_uninstall do
    case Service.uninstall() do
      :ok -> Owl.IO.puts(Owl.Data.tag("Service removed.", :green))
      {:error, reason} -> error("uninstall failed: #{inspect(reason)}")
    end
  end

  defp run_service_start do
    case Service.start() do
      :ok -> Owl.IO.puts(Owl.Data.tag("Service started.", :green))
      {:error, reason} -> error("start failed: #{inspect(reason)}")
    end
  end

  defp run_service_stop do
    case Service.stop() do
      :ok -> Owl.IO.puts(Owl.Data.tag("Service stopped.", :green))
      {:error, reason} -> error("stop failed: #{inspect(reason)}")
    end
  end

  defp run_service_status do
    case Service.status() do
      {:ok, output} -> IO.write(output)
      {:error, reason} -> error("status failed: #{inspect(reason)}")
    end
  end

  defp run_service_installed do
    if Service.installed?() do
      :ok
    else
      System.halt(1)
    end
  end

  defp run_service_logs(args) do
    case Paths.os() do
      :macos ->
        tail_args = if "-f" in args, do: ["-f"], else: []

        Port.open(
          {:spawn_executable, System.find_executable("tail") || "/usr/bin/tail"},
          [:binary, :exit_status, {:args, tail_args ++ [Paths.stdout_log()]}]
        )
        |> wait_port()

      :linux ->
        journal_args =
          ["--user", "-u", "gingko.service"] ++ if "-f" in args, do: ["-f"], else: []

        Port.open(
          {:spawn_executable, System.find_executable("journalctl") || "/usr/bin/journalctl"},
          [:binary, :exit_status, {:args, journal_args}]
        )
        |> wait_port()

      :windows ->
        run_windows_logs(args)

      :unsupported ->
        error("unsupported platform")
    end
  end

  defp run_windows_logs(args) do
    log_path = Paths.stdout_log()

    if "-f" in args do
      Port.open(
        {:spawn_executable, System.find_executable("powershell.exe") || "powershell.exe"},
        [
          :binary,
          :exit_status,
          {:args,
           [
             "-NoProfile",
             "-Command",
             "Get-Content -Wait -Tail 50 -Path \"#{log_path}\""
           ]}
        ]
      )
      |> wait_port()
    else
      case File.read(log_path) do
        {:ok, contents} -> IO.write(contents)
        {:error, :enoent} -> error("no logs at #{log_path}")
        {:error, reason} -> error("could not read #{log_path}: #{inspect(reason)}")
      end
    end
  end

  defp wait_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        wait_port(port)

      {^port, {:exit_status, _}} ->
        :ok
    end
  end

  defp error(message) do
    Owl.IO.puts(Owl.Data.tag("error: #{message}", :red), :stderr)
  end

  defp format_uptime(ms) do
    s = div(ms, 1000)
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    sec = rem(s, 60)
    "#{h}h#{m}m#{sec}s"
  end
end
