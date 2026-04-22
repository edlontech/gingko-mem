defmodule Gingko.CLI.Paths do
  @moduledoc """
  Platform-aware filesystem locations used by the Gingko CLI.

  Resolves paths to the binary, the launchd plist or systemd user unit,
  log files, the cookie file, and Burrito's extracted payload cache.
  """

  alias Gingko.Settings

  @service_label "tech.edlon.gingko"
  @node_name :"gingko@127.0.0.1"

  @spec service_label() :: String.t()
  def service_label, do: @service_label

  @spec node_name() :: node()
  def node_name, do: @node_name

  @spec os() :: :macos | :linux | :unsupported
  def os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _ -> :unsupported
    end
  end

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
  def service_unit_path do
    case os() do
      :macos ->
        Path.expand("~/Library/LaunchAgents/#{@service_label}.plist")

      :linux ->
        config_home = System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config")
        Path.join([config_home, "systemd/user/gingko.service"])

      :unsupported ->
        raise "Unsupported platform for Gingko service management"
    end
  end

  @spec log_dir() :: String.t()
  def log_dir do
    case os() do
      :macos ->
        Path.expand("~/Library/Logs/Gingko")

      :linux ->
        state_home = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
        Path.join([state_home, "gingko", "logs"])

      :unsupported ->
        Path.join(gingko_home(), "logs")
    end
  end

  @spec stdout_log() :: String.t()
  def stdout_log, do: Path.join(log_dir(), "stdout.log")

  @spec stderr_log() :: String.t()
  def stderr_log, do: Path.join(log_dir(), "stderr.log")
end
