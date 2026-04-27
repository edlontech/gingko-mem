defmodule Gingko.CLI.MemoryClient do
  @moduledoc """
  HTTP client for the Gingko `/api/*` and `/health` endpoints exposed by
  `GingkoWeb.Router`.

  Used by the Claude Code hook subcommands (`gingko hook ...`) and the
  general-purpose memory subcommands (`gingko memory ...`).

  The base URL comes from the `GINGKO_URL` environment variable and falls
  back to `http://127.0.0.1:8008`. Tests override it via the `:base_url`
  option on every function.

  Each function returns `{:ok, body}` on a 2xx response (the body is the
  decoded JSON map) or `{:error, reason}` on transport failure or non-2xx
  status. Status codes are surfaced via `{:error, {:status, code, body}}`
  so callers can distinguish between transport problems and the service
  reporting `summaries: disabled` (503), which is a normal outcome.
  """

  @default_url "http://127.0.0.1:8008"
  @default_timeout 5_000
  @health_timeout 2_000

  @type opts :: [base_url: String.t(), receive_timeout: pos_integer()]
  @type response :: {:ok, term()} | {:error, term()}

  @spec base_url() :: String.t()
  def base_url, do: System.get_env("GINGKO_URL") || @default_url

  @spec health(opts()) :: response()
  def health(opts \\ []),
    do:
      request(:get, "/health", nil, [], Keyword.put_new(opts, :receive_timeout, @health_timeout))

  @spec open_project(String.t(), opts()) :: response()
  def open_project(project_id, opts \\ []),
    do: request(:post, "/api/projects/#{enc(project_id)}/open", %{}, [], opts)

  @spec start_session(String.t(), map(), opts()) :: response()
  def start_session(project_id, body, opts \\ []) when is_map(body),
    do: request(:post, "/api/projects/#{enc(project_id)}/sessions", body, [], opts)

  @spec append_step(String.t(), String.t(), String.t(), opts()) :: response()
  def append_step(session_id, observation, action, opts \\ []),
    do:
      request(
        :post,
        "/api/sessions/#{enc(session_id)}/steps",
        %{observation: observation, action: action},
        [],
        opts
      )

  @spec commit_session(String.t(), opts()) :: response()
  def commit_session(session_id, opts \\ []),
    do: request(:post, "/api/sessions/#{enc(session_id)}/commit", %{}, [], opts)

  @spec summarize_session(String.t(), String.t(), opts()) :: response()
  def summarize_session(session_id, content, opts \\ []),
    do:
      request(
        :post,
        "/api/sessions/#{enc(session_id)}/summarize",
        %{content: content},
        [],
        Keyword.put_new(opts, :receive_timeout, 10_000)
      )

  @spec recall(String.t(), String.t(), opts()) :: response()
  def recall(project_id, query, opts \\ []),
    do: request(:get, "/api/projects/#{enc(project_id)}/recall", nil, [{"query", query}], opts)

  @spec get_node(String.t(), String.t(), opts()) :: response()
  def get_node(project_id, node_id, opts \\ []),
    do:
      request(
        :get,
        "/api/projects/#{enc(project_id)}/nodes/#{enc(node_id)}",
        nil,
        [],
        opts
      )

  @spec latest_memories(String.t(), pos_integer(), :json | :markdown, opts()) :: response()
  def latest_memories(project_id, top_k \\ 30, format \\ :json, opts \\ []) do
    params =
      [{"top_k", Integer.to_string(top_k)}] ++
        case format do
          :markdown -> [{"format", "markdown"}]
          :json -> []
        end

    request(:get, "/api/projects/#{enc(project_id)}/latest", nil, params, opts)
  end

  @spec session_primer(String.t(), opts()) :: response()
  def session_primer(project_id, opts \\ []),
    do: request(:get, "/api/projects/#{enc(project_id)}/session_primer", nil, [], opts)

  @spec summaries_status(opts()) :: response()
  def summaries_status(opts \\ []),
    do: request(:get, "/api/summaries/status", nil, [], opts)

  defp request(method, path, body, params, opts) do
    base = Keyword.get(opts, :base_url, base_url())
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)
    passthrough = Keyword.drop(opts, [:base_url, :receive_timeout])

    req_opts =
      [
        method: method,
        url: base <> path,
        params: params,
        receive_timeout: timeout,
        retry: false
      ]
      |> maybe_put_json(body)
      |> Keyword.merge(passthrough)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, body), do: Keyword.put(opts, :json, body)

  defp enc(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
