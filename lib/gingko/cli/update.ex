defmodule Gingko.CLI.Update do
  @moduledoc """
  Self-update for Burrito-packaged Gingko binaries.

  Fetches the latest release from GitHub, picks the asset matching the
  current platform, downloads it to a temp file, and replaces the running
  binary in place. If a user-level service is installed, it is stopped
  before the swap and started afterwards.

  Burrito notices the version change on next boot and re-extracts its
  payload automatically, so we do not need to clear any caches.
  """

  alias Gingko.CLI.Paths
  alias Gingko.CLI.Service

  @repo "edlontech/gingko-mem"
  @releases_url "https://api.github.com/repos/#{@repo}/releases/latest"
  @download_timeout 120_000

  @type opts :: [
          force: boolean(),
          binary_path: String.t(),
          os: Paths.os_atom(),
          arch: String.t(),
          releases_url: String.t(),
          current_version: String.t(),
          req_options: keyword(),
          io: module()
        ]

  @spec run([String.t()] | opts()) :: :ok | {:error, term()}
  def run(args \\ [])

  def run(args) when is_list(args) do
    cond do
      Keyword.keyword?(args) -> run_with_opts(args)
      true -> run_with_opts(force: "--force" in args)
    end
  end

  defp run_with_opts(opts) do
    io = Keyword.get(opts, :io, Owl.IO)

    with {:ok, current_path} <- resolve_binary(opts),
         {:ok, target} <- resolve_target(opts),
         {:ok, current_version} <- resolve_current_version(opts),
         {:ok, release} <- fetch_release(opts),
         {:ok, latest_version} <- parse_tag(release["tag_name"]),
         :continue <-
           decide(current_version, latest_version, Keyword.get(opts, :force, false), io),
         {:ok, asset} <- pick_asset(release, target, io),
         {:ok, tmp_path} <- download_asset(asset, opts, io),
         :ok <- swap_binary(current_path, tmp_path, target, io),
         :ok <- bounce_service(io) do
      ok(io, "Updated to #{latest_version}.")
      :ok
    else
      :already_up_to_date ->
        :ok

      {:error, reason} = error ->
        fail(io, "update failed: #{format_error(reason)}")
        error
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

  defp resolve_current_version(opts) do
    case Keyword.get(opts, :current_version) do
      version when is_binary(version) and version != "" ->
        {:ok, version}

      _ ->
        case Application.spec(:gingko, :vsn) do
          nil -> {:error, :current_version_unknown}
          vsn -> {:ok, List.to_string(vsn)}
        end
    end
  end

  defp fetch_release(opts) do
    url = Keyword.get(opts, :releases_url, @releases_url)

    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "gingko-update"}
    ]

    case Req.get(
           Keyword.merge(
             [url: url, headers: headers, retry: false, receive_timeout: 15_000],
             Keyword.get(opts, :req_options, [])
           )
         ) do
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

  defp decide(current, latest, force, io) do
    cond do
      force ->
        info(io, "Forcing reinstall of #{latest}.")
        :continue

      newer?(latest, current) ->
        info(io, "Upgrading #{current} → #{latest}")
        :continue

      true ->
        ok(io, "Already on #{current}. Nothing to do.")
        :already_up_to_date
    end
  end

  defp newer?(latest, current) do
    case {Version.parse(latest), Version.parse(current)} do
      {{:ok, l}, {:ok, c}} -> Version.compare(l, c) == :gt
      _ -> false
    end
  end

  defp pick_asset(release, target, io) do
    expected_name = "gingko_#{target.alias}#{target.ext}"
    assets = Map.get(release, "assets") || []

    case Enum.find(assets, fn asset -> Map.get(asset, "name") == expected_name end) do
      nil ->
        fail(io, "no asset named #{expected_name} in release #{release["tag_name"]}.")
        {:error, {:asset_missing, expected_name}}

      asset ->
        {:ok, asset}
    end
  end

  defp download_asset(asset, opts, io) do
    url = Map.fetch!(asset, "browser_download_url")
    name = Map.fetch!(asset, "name")
    info(io, "Downloading #{name}…")

    tmp_path = Path.join(System.tmp_dir!(), "#{name}.#{System.unique_integer([:positive])}")

    req_opts =
      Keyword.merge(
        [
          url: url,
          headers: [{"accept", "application/octet-stream"}, {"user-agent", "gingko-update"}],
          retry: false,
          receive_timeout: @download_timeout,
          into: File.stream!(tmp_path)
        ],
        Keyword.get(opts, :req_options, [])
      )

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

  defp swap_binary(current_path, new_path, %{os: :windows}, io) do
    info(io, "Staging new binary at #{current_path}.new (Windows can't replace a running .exe).")

    with :ok <- File.cp(new_path, current_path <> ".new"),
         _ = File.rm(new_path) do
      info(
        io,
        "Stop the service, run `move /Y \"#{current_path}.new\" \"#{current_path}\"`, then start it again."
      )

      :ok
    end
  end

  defp swap_binary(current_path, new_path, _target, io) do
    info(io, "Replacing #{current_path}")

    with :ok <- File.chmod(new_path, 0o755),
         :ok <- File.rename(new_path, current_path) do
      :ok
    else
      {:error, :exdev} ->
        with :ok <- File.cp(new_path, current_path),
             _ = File.rm(new_path) do
          :ok
        end

      error ->
        error
    end
  end

  defp bounce_service(io) do
    cond do
      not Service.installed?() ->
        info(io, "No service installed; restart Gingko manually if it was running.")
        :ok

      Paths.os() == :windows ->
        info(io, "Skipping service restart on Windows; complete the .new swap manually.")
        :ok

      true ->
        _ = Service.stop()
        info(io, "Service stopped. Starting new version…")

        case Service.start() do
          :ok ->
            ok(io, "Service started.")
            :ok

          {:error, reason} ->
            {:error, {:service_start, reason}}
        end
    end
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

  defp ok(io, message), do: io.puts(Owl.Data.tag(message, :green))
  defp info(io, message), do: io.puts(message)
  defp fail(io, message), do: io.puts(Owl.Data.tag("error: #{message}", :red), :stderr)

  defp format_error(:binary_path_unknown),
    do: "could not locate the running Gingko binary (__BURRITO_BIN_PATH unset)."

  defp format_error(:current_version_unknown), do: "unable to read current Gingko version."
  defp format_error(:no_releases_published), do: "no releases published yet on GitHub."
  defp format_error({:github_status, status}), do: "GitHub returned HTTP #{status}."
  defp format_error({:github, reason}), do: "GitHub request failed: #{inspect(reason)}."
  defp format_error({:asset_missing, name}), do: "asset #{name} not found in release."
  defp format_error({:download_status, status}), do: "download returned HTTP #{status}."
  defp format_error({:download, reason}), do: "download error: #{inspect(reason)}."
  defp format_error({:unsupported_target, os, arch}), do: "no Burrito target for #{os}/#{arch}."
  defp format_error({:service_start, reason}), do: "service start failed: #{inspect(reason)}."
  defp format_error(other), do: inspect(other)
end
