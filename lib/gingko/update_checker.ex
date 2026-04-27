defmodule Gingko.UpdateChecker do
  @moduledoc """
  Periodically polls GitHub for the latest Gingko release and broadcasts the
  result on `Gingko.PubSub` so the web UI can surface available updates.
  """

  use GenServer

  require Logger

  @repo "edlontech/gingko-mem"
  @release_url "https://api.github.com/repos/#{@repo}/releases/latest"
  @check_interval :timer.hours(6)
  @retry_interval :timer.minutes(15)
  @topic "updates:status"
  @persistent_key {__MODULE__, :status}

  @type info :: %{current: String.t(), latest: String.t(), html_url: String.t()}
  @type status :: :unknown | :up_to_date | {:update_available, info()}

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            current: String.t() | nil,
            status: Gingko.UpdateChecker.status(),
            checked_at: DateTime.t() | nil,
            timer_ref: reference() | nil,
            interval: pos_integer(),
            retry_interval: pos_integer(),
            url: String.t()
          }
    defstruct [
      :current,
      :status,
      :checked_at,
      :timer_ref,
      :interval,
      :retry_interval,
      :url
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the cached update status. Reads from `:persistent_term` so callers
  in the render path do not block on a `GenServer.call/2`.
  """
  @spec status() :: status()
  def status, do: :persistent_term.get(@persistent_key, :unknown)

  @doc "Forces an immediate check (asynchronous)."
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server \\ __MODULE__), do: GenServer.cast(server, :check_now)

  @doc "Returns the running Gingko version, when known."
  @spec current_version() :: String.t() | nil
  def current_version do
    case Application.spec(:gingko, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Extracts a SemVer string from a release tag, ignoring any prefix
  such as `v` or `gingko-v` (e.g. `"gingko-v0.1.0"` -> `"0.1.0"`).
  Returns the original tag when no SemVer pattern is present.
  """
  @spec parse_tag(String.t()) :: String.t()
  def parse_tag(tag) when is_binary(tag) do
    case Regex.run(~r/v?(\d+\.\d+\.\d+(?:[-+][\w.\-+]+)?)/, tag) do
      [_, version] -> version
      _ -> tag
    end
  end

  @doc "PubSub topic broadcast on every status change."
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(opts) do
    state = %State{
      current: opts |> Keyword.get(:current_version) |> normalize_current(),
      status: :unknown,
      checked_at: nil,
      timer_ref: nil,
      interval: Keyword.get(opts, :interval, @check_interval),
      retry_interval: Keyword.get(opts, :retry_interval, @retry_interval),
      url: Keyword.get(opts, :url, @release_url)
    }

    :persistent_term.put(@persistent_key, state.status)
    {:ok, state, {:continue, :first_check}}
  end

  @impl true
  def handle_continue(:first_check, state), do: {:noreply, run_check(state)}

  @impl true
  def handle_cast(:check_now, state) do
    cancel_timer(state.timer_ref)
    {:noreply, run_check(%{state | timer_ref: nil})}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, run_check(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp run_check(state) do
    {next_status, next_interval} =
      case fetch_latest(state.url) do
        {:ok, %{tag: tag, html_url: html_url}} ->
          {compare(state.current, tag, html_url), state.interval}

        {:error, :no_release} ->
          {:up_to_date, state.interval}

        {:error, reason} ->
          Logger.debug("UpdateChecker fetch failed: #{inspect(reason)}")
          {state.status, state.retry_interval}
      end

    if next_status != state.status do
      :persistent_term.put(@persistent_key, next_status)
      Phoenix.PubSub.broadcast(Gingko.PubSub, @topic, {:update_status, next_status})
    end

    timer_ref = Process.send_after(self(), :tick, next_interval)

    %{state | status: next_status, checked_at: DateTime.utc_now(), timer_ref: timer_ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp fetch_latest(url) do
    headers = [
      {"accept", "application/vnd.github+json"},
      {"user-agent", "gingko-update-checker"}
    ]

    case Req.get(url: url, headers: headers, retry: false, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => tag} = body}} ->
        {:ok,
         %{
           tag: tag,
           html_url: Map.get(body, "html_url", "https://github.com/#{@repo}/releases/latest")
         }}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :no_release}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compare(nil, _tag, _url), do: :unknown

  defp compare(current, tag, url) do
    latest = parse_tag(tag)

    case {Version.parse(current), Version.parse(latest)} do
      {{:ok, c}, {:ok, l}} ->
        if Version.compare(l, c) == :gt do
          {:update_available, %{current: current, latest: latest, html_url: url}}
        else
          :up_to_date
        end

      _ ->
        :unknown
    end
  end

  defp normalize_current(nil) do
    case Application.spec(:gingko, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  defp normalize_current(version) when is_binary(version), do: version
  defp normalize_current(version) when is_list(version), do: List.to_string(version)
end
