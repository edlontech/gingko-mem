defmodule Gingko.UpdateApplier do
  @moduledoc """
  In-process applier that downloads the latest matching Gingko release,
  atomically swaps it over the running binary, and exits the BEAM with
  a non-zero code so the user-level service manager (launchd / systemd /
  Scheduled Tasks) auto-restarts the new version.

  Progress is broadcast on `Gingko.PubSub` topic `"updates:apply"` so the
  web UI can render a status indicator while the LiveView WebSocket is
  briefly disconnected during the restart.
  """

  require Logger

  alias Gingko.CLI.Paths
  alias Gingko.CLI.Service

  @repo "edlontech/gingko-mem"
  @releases_url "https://api.github.com/repos/#{@repo}/releases/latest"
  @download_timeout 120_000
  @restart_grace_ms 750
  @halt_code 99
  @topic "updates:apply"

  @type stage ::
          :idle
          | :starting
          | :downloading
          | :swapping
          | :restarting
          | {:error, term()}
          | {:done, String.t()}

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Returns true when the running binary is supervised by a service manager."
  @spec restart_supervised?() :: boolean()
  def restart_supervised?, do: Service.installed?() and Paths.binary_path() != nil

  @doc """
  Kicks off the apply pipeline as a supervised task. The caller returns
  immediately; progress is delivered via PubSub messages of the form
  `{:apply_progress, stage}`.
  """
  @spec start_async(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_async(opts \\ []) do
    case Task.Supervisor.start_child(
           Gingko.TaskSupervisor,
           fn -> run(opts) end,
           restart: :temporary
         ) do
      {:ok, pid} -> {:ok, pid}
      other -> other
    end
  end

  @doc false
  @spec run(keyword()) :: :ok
  def run(opts) do
    broadcast(:starting)

    with {:ok, binary_path} <- resolve_binary(opts),
         {:ok, target} <- resolve_target(opts),
         {:ok, release} <- fetch_release(opts),
         {:ok, latest} <- parse_tag(release["tag_name"]),
         {:ok, asset} <- pick_asset(release, target),
         broadcast(:downloading),
         {:ok, tmp_path} <- download(asset, opts),
         broadcast(:swapping),
         :ok <- swap(binary_path, tmp_path),
         broadcast(:restarting),
         :ok <- maybe_halt(opts) do
      broadcast({:done, latest})
      :ok
    else
      {:error, reason} ->
        Logger.error("UpdateApplier failed: #{inspect(reason)}")
        broadcast({:error, reason})
        :ok
    end
  end

  defp resolve_binary(opts) do
    case Keyword.get(opts, :binary_path) || Paths.binary_path() do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :binary_path_unknown}
    end
  end

  defp resolve_target(opts) do
    os = Keyword.get(opts, :os) || Paths.os()
    arch = Keyword.get(opts, :arch) || system_arch()

    case asset_alias(os, arch) do
      nil -> {:error, {:unsupported_target, os, arch}}
      alias_name -> {:ok, %{os: os, alias: alias_name, ext: extension(os)}}
    end
  end

  defp fetch_release(opts) do
    url = Keyword.get(opts, :releases_url, @releases_url)

    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "gingko-update"}
    ]

    case Req.get(url: url, headers: headers, retry: false, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :no_releases_published}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:github_status, status}}

      {:error, reason} ->
        {:error, {:github, reason}}
    end
  end

  defp parse_tag(tag) when is_binary(tag), do: {:ok, Gingko.UpdateChecker.parse_tag(tag)}
  defp parse_tag(_), do: {:error, :invalid_tag}

  defp pick_asset(release, target) do
    expected = "gingko_#{target.alias}#{target.ext}"
    assets = Map.get(release, "assets") || []

    case Enum.find(assets, fn a -> Map.get(a, "name") == expected end) do
      nil -> {:error, {:asset_missing, expected}}
      asset -> {:ok, asset}
    end
  end

  defp download(asset, _opts) do
    url = Map.fetch!(asset, "browser_download_url")
    name = Map.fetch!(asset, "name")
    tmp_path = Path.join(System.tmp_dir!(), "#{name}.#{System.unique_integer([:positive])}")

    req_opts = [
      url: url,
      headers: [{"accept", "application/octet-stream"}, {"user-agent", "gingko-update"}],
      retry: false,
      receive_timeout: @download_timeout,
      into: File.stream!(tmp_path)
    ]

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, tmp_path}

      {:ok, %Req.Response{status: status}} ->
        _ = File.rm(tmp_path)
        {:error, {:download_status, status}}

      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, {:download, reason}}
    end
  end

  defp swap(binary_path, tmp_path) do
    with :ok <- File.chmod(tmp_path, 0o755),
         :ok <- File.rename(tmp_path, binary_path) do
      :ok
    else
      {:error, :exdev} ->
        with :ok <- File.cp(tmp_path, binary_path) do
          _ = File.rm(tmp_path)
          :ok
        end

      error ->
        error
    end
  end

  defp maybe_halt(opts) do
    case Keyword.get(opts, :halt, true) do
      false ->
        :ok

      _ ->
        spawn(fn ->
          Process.sleep(@restart_grace_ms)
          System.halt(@halt_code)
        end)

        :ok
    end
  end

  defp broadcast(stage) do
    Phoenix.PubSub.broadcast(Gingko.PubSub, @topic, {:apply_progress, stage})
    :ok
  end

  defp asset_alias(:macos, "aarch64"), do: "macos_silicon"
  defp asset_alias(:macos, "arm64"), do: "macos_silicon"
  defp asset_alias(:linux, "aarch64"), do: "linux_arm"
  defp asset_alias(:linux, "arm64"), do: "linux_arm"
  defp asset_alias(:linux, "x86_64"), do: "linux"
  defp asset_alias(:linux, "amd64"), do: "linux"
  defp asset_alias(:windows, "x86_64"), do: "windows"
  defp asset_alias(:windows, "amd64"), do: "windows"
  defp asset_alias(_os, _arch), do: nil

  defp extension(:windows), do: ".exe"
  defp extension(_), do: ""

  defp system_arch do
    :erlang.system_info(:system_architecture)
    |> List.to_string()
    |> String.split("-", parts: 2)
    |> List.first()
  end
end
