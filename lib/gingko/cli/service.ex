defmodule Gingko.CLI.Service do
  @moduledoc """
  Manages the platform-specific user-level service registration for Gingko.

  On macOS this installs a LaunchAgent plist under
  `~/Library/LaunchAgents`. On Linux it installs a systemd user unit
  under `~/.config/systemd/user`. On Windows it registers a per-user
  Scheduled Task at logon via `schtasks.exe`. None require root.
  """

  alias Gingko.CLI.Paths

  @spec install() :: :ok | {:error, term()}
  def install do
    case Paths.os() do
      :macos -> install_macos()
      :linux -> install_linux()
      :windows -> install_windows()
      :unsupported -> {:error, :unsupported_platform}
    end
  end

  @spec uninstall() :: :ok | {:error, term()}
  def uninstall do
    case Paths.os() do
      :macos -> uninstall_macos()
      :linux -> uninstall_linux()
      :windows -> uninstall_windows()
      :unsupported -> {:error, :unsupported_platform}
    end
  end

  @spec start() :: :ok | {:error, term()}
  def start do
    case Paths.os() do
      :macos ->
        with {:ok, uid} <- user_id(),
             {_, 0} <-
               System.cmd("launchctl", ["kickstart", "gui/#{uid}/#{Paths.service_label()}"],
                 stderr_to_stdout: true
               ) do
          :ok
        else
          {output, code} when is_binary(output) -> {:error, {:launchctl, code, output}}
          error -> error
        end

      :linux ->
        run_systemctl(["start", "gingko.service"])

      :windows ->
        run_schtasks(["/Run", "/TN", Paths.service_label()])

      :unsupported ->
        {:error, :unsupported_platform}
    end
  end

  @spec stop() :: :ok | {:error, term()}
  def stop do
    case Paths.os() do
      :macos ->
        with {:ok, uid} <- user_id(),
             {_, 0} <-
               System.cmd(
                 "launchctl",
                 ["kill", "SIGTERM", "gui/#{uid}/#{Paths.service_label()}"],
                 stderr_to_stdout: true
               ) do
          :ok
        else
          {output, code} when is_binary(output) -> {:error, {:launchctl, code, output}}
          error -> error
        end

      :linux ->
        run_systemctl(["stop", "gingko.service"])

      :windows ->
        run_schtasks(["/End", "/TN", Paths.service_label()])

      :unsupported ->
        {:error, :unsupported_platform}
    end
  end

  @spec status() :: {:ok, String.t()} | {:error, term()}
  def status do
    case Paths.os() do
      :macos ->
        with {:ok, uid} <- user_id() do
          {output, _code} =
            System.cmd("launchctl", ["print", "gui/#{uid}/#{Paths.service_label()}"],
              stderr_to_stdout: true
            )

          {:ok, output}
        end

      :linux ->
        {output, _code} =
          System.cmd("systemctl", ["--user", "status", "gingko.service", "--no-pager"],
            stderr_to_stdout: true
          )

        {:ok, output}

      :windows ->
        {output, _code} =
          System.cmd(
            "schtasks.exe",
            ["/Query", "/TN", Paths.service_label(), "/V", "/FO", "LIST"],
            stderr_to_stdout: true
          )

        {:ok, output}

      :unsupported ->
        {:error, :unsupported_platform}
    end
  end

  @spec installed?() :: boolean()
  def installed?, do: File.exists?(Paths.service_unit_path())

  defp install_macos do
    with {:ok, binary} <- resolve_binary(),
         :ok <- ensure_log_dir(),
         plist = render_plist(binary),
         unit_path = Paths.service_unit_path(),
         :ok <- File.mkdir_p(Path.dirname(unit_path)),
         :ok <- File.write(unit_path, plist),
         {:ok, uid} <- user_id() do
      bootstrap_launchd(uid, unit_path)
    end
  end

  defp install_linux do
    with {:ok, binary} <- resolve_binary(),
         unit = render_systemd_unit(binary),
         unit_path = Paths.service_unit_path(),
         :ok <- File.mkdir_p(Path.dirname(unit_path)),
         :ok <- File.write(unit_path, unit),
         :ok <- run_systemctl(["daemon-reload"]) do
      run_systemctl(["enable", "--now", "gingko.service"])
    end
  end

  defp install_windows do
    with {:ok, binary} <- resolve_binary(),
         :ok <- ensure_log_dir(),
         xml = render_task_xml(binary),
         unit_path = Paths.service_unit_path(),
         :ok <- File.mkdir_p(Path.dirname(unit_path)),
         :ok <- File.write(unit_path, encode_utf16_le_with_bom(xml)) do
      run_schtasks(["/Create", "/TN", Paths.service_label(), "/XML", unit_path, "/F"])
    end
  end

  defp uninstall_macos do
    unit_path = Paths.service_unit_path()

    case user_id() do
      {:ok, uid} ->
        _ =
          System.cmd(
            "launchctl",
            ["bootout", "gui/#{uid}/#{Paths.service_label()}"],
            stderr_to_stdout: true
          )

        case File.rm(unit_path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp uninstall_linux do
    _ = run_systemctl(["disable", "--now", "gingko.service"])
    unit_path = Paths.service_unit_path()

    case File.rm(unit_path) do
      :ok ->
        _ = run_systemctl(["daemon-reload"])
        :ok

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  defp uninstall_windows do
    _ = run_schtasks(["/Delete", "/TN", Paths.service_label(), "/F"])
    unit_path = Paths.service_unit_path()

    case File.rm(unit_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp bootstrap_launchd(uid, unit_path) do
    case System.cmd("launchctl", ["bootstrap", "gui/#{uid}", unit_path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:launchctl, code, output}}
    end
  end

  defp run_systemctl(args) do
    case System.cmd("systemctl", ["--user" | args], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:systemctl, code, output}}
    end
  end

  defp run_schtasks(args) do
    case System.cmd("schtasks.exe", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:schtasks, code, output}}
    end
  end

  defp render_plist(binary) do
    template = read_template!("launchd.plist.eex")

    EEx.eval_string(template,
      assigns: [
        label: Paths.service_label(),
        binary_path: binary,
        gingko_home: Paths.gingko_home(),
        stdout_log: Paths.stdout_log(),
        stderr_log: Paths.stderr_log()
      ]
    )
  end

  defp render_systemd_unit(binary) do
    template = read_template!("gingko.service.eex")

    EEx.eval_string(template,
      assigns: [
        binary_path: binary,
        gingko_home: Paths.gingko_home()
      ]
    )
  end

  defp render_task_xml(binary) do
    template = read_template!("gingko.task.xml.eex")

    EEx.eval_string(template,
      assigns: [
        label: Paths.service_label(),
        binary_path: binary,
        gingko_home: Paths.gingko_home()
      ]
    )
  end

  defp encode_utf16_le_with_bom(content) do
    <<0xFF, 0xFE>> <> :unicode.characters_to_binary(content, :utf8, {:utf16, :little})
  end

  defp read_template!(name) do
    :gingko
    |> :code.priv_dir()
    |> Path.join(["templates/", name])
    |> File.read!()
  end

  defp resolve_binary do
    case Paths.binary_path() do
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, :binary_path_unknown}
    end
  end

  defp ensure_log_dir do
    File.mkdir_p(Paths.log_dir())
  end

  defp user_id do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:id, code, out}}
    end
  end

  @spec linger_enabled?() :: boolean()
  def linger_enabled? do
    user = System.get_env("USER") || ""

    case System.cmd("loginctl", ["show-user", user, "--property=Linger"], stderr_to_stdout: true) do
      {out, 0} -> String.contains?(out, "Linger=yes")
      _ -> false
    end
  rescue
    ErlangError -> false
  end
end
