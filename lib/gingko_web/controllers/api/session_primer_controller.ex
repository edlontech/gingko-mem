defmodule GingkoWeb.Api.SessionPrimerController do
  use GingkoWeb, :controller

  alias Gingko.Summaries

  action_fallback GingkoWeb.Api.FallbackController

  def show(conn, %{"project_id" => project_id} = params) do
    with {:ok, opts} <- build_opts(params),
         {:ok, content} <- Summaries.render_primer(project_id, opts) do
      json(conn, %{format: "markdown", content: content})
    end
  end

  defp build_opts(params) do
    case params["recent_count"] do
      nil ->
        {:ok, []}

      n when is_integer(n) ->
        {:ok, [recent_count: n]}

      n when is_binary(n) ->
        case Integer.parse(n) do
          {int, ""} ->
            {:ok, [recent_count: int]}

          _ ->
            {:error, %{code: :invalid_params, message: "`recent_count` must be an integer"}}
        end

      _ ->
        {:error, %{code: :invalid_params, message: "`recent_count` must be an integer"}}
    end
  end
end
