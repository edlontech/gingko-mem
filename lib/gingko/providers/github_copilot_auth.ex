defmodule Gingko.Providers.GithubCopilotAuth do
  @moduledoc """
  GitHub OAuth device flow against the VS Code Copilot OAuth App.

  Mirrors what the upstream Copilot script does: register a device code,
  poll for approval, then verify the resulting `gho_...` token works
  against `copilot_internal/v2/token`. The resulting token is what
  Sycophant feeds to `Sycophant.Auth.GithubCopilot` as `:github_token`.

  Calls split into two phases so the UI can render the user code +
  verification URL right away while the polling continues asynchronously.

  ## Configuration

  Override the HTTP client (e.g. for tests) with:

      config :gingko, #{inspect(__MODULE__)}, http: MyStubModule

  The module behind `:http` must implement `post/2` and `get/2` returning
  `Req.Response.t()` (or anything with `:status` and `:body` fields).
  """

  @client_id "Iv1.b507a08c87ecfe98"
  @scope "read:user"

  @device_code_url "https://github.com/login/device/code"
  @access_token_url "https://github.com/login/oauth/access_token"
  @verify_url "https://api.github.com/copilot_internal/v2/token"

  @editor_version "vscode/1.95.0"
  @editor_plugin_version "copilot-chat/0.22.0"
  @user_agent "GitHubCopilotChat/0.22.0"

  @typedoc "Initial device-flow data returned to the user."
  @type device_code :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          interval: pos_integer(),
          expires_in: pos_integer()
        }

  @doc """
  Requests a device code. The caller should display `:user_code` and direct
  the user to `:verification_uri`, then call `poll_for_token/2` with the
  returned `:device_code` and `:interval`.
  """
  @spec start_device_flow() :: {:ok, device_code()} | {:error, term()}
  def start_device_flow do
    case http().post(@device_code_url,
           headers: [{"accept", "application/json"}],
           form: [client_id: @client_id, scope: @scope]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok,
         %{
           device_code: body["device_code"],
           user_code: body["user_code"],
           verification_uri: body["verification_uri"],
           interval: body["interval"] || 5,
           expires_in: body["expires_in"] || 900
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Polls the OAuth access-token endpoint until the user approves, the flow
  expires, or GitHub returns a fatal error. Sleeps between polls using
  `interval` (or the slow-down value GitHub returns).

  `opts`:
    * `:max_polls` (default `180`) – cap on iterations to prevent runaways.
    * `:on_tick` – fun/1 called with `:pending` or `:slow_down` each poll;
      the LiveView wires this for progress feedback.
  """
  @spec poll_for_token(String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def poll_for_token(device_code, interval, opts \\ []) do
    max_polls = Keyword.get(opts, :max_polls, 180)
    on_tick = Keyword.get(opts, :on_tick, fn _ -> :ok end)
    do_poll(device_code, interval, max_polls, on_tick)
  end

  defp do_poll(_device_code, _interval, 0, _on_tick), do: {:error, :timeout}

  defp do_poll(device_code, interval, remaining, on_tick) do
    sleeper().(interval * 1_000)

    case http().post(@access_token_url,
           headers: [{"accept", "application/json"}],
           form: [
             client_id: @client_id,
             device_code: device_code,
             grant_type: "urn:ietf:params:oauth:grant-type:device_code"
           ]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: 200, body: %{"error" => "authorization_pending"}}} ->
        on_tick.(:pending)
        do_poll(device_code, interval, remaining - 1, on_tick)

      {:ok, %{status: 200, body: %{"error" => "slow_down"}}} ->
        on_tick.(:slow_down)
        do_poll(device_code, interval + 5, remaining - 1, on_tick)

      {:ok, %{status: 200, body: %{"error" => err}}} ->
        {:error, {:github, err}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Verifies a `gho_...` token works against the Copilot internal token
  endpoint. Returns `{:ok, copilot_metadata}` on success.
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token(github_token) do
    case http().get(@verify_url,
           headers: [
             {"authorization", "token #{github_token}"},
             {"accept", "application/json"},
             {"user-agent", @user_agent},
             {"editor-version", @editor_version},
             {"editor-plugin-version", @editor_plugin_version}
           ]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http do
    config = Application.get_env(:gingko, __MODULE__, [])
    Keyword.get(config, :http, __MODULE__.ReqClient)
  end

  defp sleeper do
    config = Application.get_env(:gingko, __MODULE__, [])
    Keyword.get(config, :sleeper, &Process.sleep/1)
  end

  defmodule ReqClient do
    @moduledoc false

    def post(url, opts) do
      try do
        {:ok, Req.post!(url, opts)}
      rescue
        e -> {:error, e}
      end
    end

    def get(url, opts) do
      try do
        {:ok, Req.get!(url, opts)}
      rescue
        e -> {:error, e}
      end
    end
  end
end
