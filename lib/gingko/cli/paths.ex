defmodule Gingko.CLI.Paths do
  @moduledoc """
  Platform-aware filesystem locations used by the Gingko CLI.

  Resolves paths to the binary, the launchd plist / systemd user unit /
  Windows Scheduled Task XML, log files, the cookie file, and Burrito's
  extracted payload cache.
  """

  alias Gingko.Settings

  @service_label "tech.edlon.gingko"
  @node_name :"gingko@127.0.0.1"

  @type os_atom :: :macos | :linux | :windows | :unsupported

  @spec service_label() :: String.t()
  def service_label, do: @service_label

  @spec node_name() :: node()
  def node_name, do: @node_name

  @spec os() :: os_atom()
  def os, do: classify_os(:os.type())

  @spec classify_os({:unix | :win32, atom()}) :: os_atom()
  def classify_os({:unix, :darwin}), do: :macos
  def classify_os({:unix, :linux}), do: :linux
  def classify_os({:win32, _}), do: :windows
  def classify_os(_), do: :unsupported

  @spec gingko_home() :: String.t()
  def gingko_home, do: Settings.home()

  @spec cookie_file() :: String.t()
  def cookie_file, do: Path.join(gingko_home(), ".cookie")

  @spec binary_path() :: String.t() | nil
  def binary_path do
    case System.get_env("__BURRITO_BIN_PATH") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @spec release_root() :: String.t() | nil
  def release_root do
    case System.get_env("RELEASE_ROOT") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @spec burrito_cache_dir() :: String.t() | nil
  def burrito_cache_dir do
    case release_root() do
      nil -> nil
      path -> Path.dirname(path)
    end
  end

  @spec erl_executable() :: String.t() | nil
  def erl_executable do
    with root when is_binary(root) <- release_root(),
         [erts_dir | _] <- Path.wildcard(Path.join(root, "erts-*")) do
      Path.join([erts_dir, "bin", "erl"])
    else
      _ -> nil
    end
  end

  @spec service_unit_path() :: String.t()
  def service_unit_path, do: service_unit_path(os())

  @spec service_unit_path(os_atom()) :: String.t()
  def service_unit_path(:macos),
    do: Path.expand("~/Library/LaunchAgents/#{@service_label}.plist")

  def service_unit_path(:linux), do: linux_systemd_unit_path(System.get_env("XDG_CONFIG_HOME"))

  def service_unit_path(:windows), do: windows_task_xml_path(System.get_env("LOCALAPPDATA"))

  def service_unit_path(:unsupported),
    do: raise("Unsupported platform for Gingko service management")

  @spec log_dir() :: String.t()
  def log_dir, do: log_dir(os())

  @spec log_dir(os_atom()) :: String.t()
  def log_dir(:macos), do: Path.expand("~/Library/Logs/Gingko")

  def log_dir(:linux), do: linux_log_dir(System.get_env("XDG_STATE_HOME"))

  def log_dir(:windows), do: windows_log_dir(System.get_env("LOCALAPPDATA"))

  def log_dir(:unsupported), do: Path.join(gingko_home(), "logs")

  @spec stdout_log() :: String.t()
  def stdout_log, do: Path.join(log_dir(), "stdout.log")

  @spec stderr_log() :: String.t()
  def stderr_log, do: Path.join(log_dir(), "stderr.log")

  @spec local_appdata() :: String.t()
  def local_appdata, do: local_appdata(System.get_env("LOCALAPPDATA"))

  @doc false
  @spec local_appdata(String.t() | nil) :: String.t()
  def local_appdata(value) when is_binary(value) and value != "", do: value
  def local_appdata(_), do: Path.join([System.user_home!(), "AppData", "Local"])

  @doc false
  def linux_systemd_unit_path(xdg_config_home) do
    config_home =
      if xdg_config_home in [nil, ""], do: Path.expand("~/.config"), else: xdg_config_home

    Path.join([config_home, "systemd/user/gingko.service"])
  end

  @doc false
  def linux_log_dir(xdg_state_home) do
    state_home =
      if xdg_state_home in [nil, ""], do: Path.expand("~/.local/state"), else: xdg_state_home

    Path.join([state_home, "gingko", "logs"])
  end

  @doc false
  def windows_task_xml_path(local_appdata) do
    Path.join(local_appdata(local_appdata), "Gingko\\gingko.task.xml")
  end

  @doc false
  def windows_log_dir(local_appdata) do
    Path.join(local_appdata(local_appdata), "Gingko\\logs")
  end
end
