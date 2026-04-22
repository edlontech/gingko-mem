defmodule GingkoWeb.Api.LatestMemoriesController do
  @moduledoc false

  use GingkoWeb, :controller

  alias Gingko.Memory.MarkdownRenderer

  action_fallback GingkoWeb.Api.FallbackController

  def index(conn, %{"project_id" => project_id} = params) do
    attrs = build_attrs(project_id, params)

    with {:ok, result} <- Gingko.Memory.latest_memories(attrs) do
      respond(conn, result, params["format"])
    end
  end

  defp respond(conn, result, "markdown") do
    markdown = MarkdownRenderer.render(result.memories)
    json(conn, %{format: "markdown", content: markdown})
  end

  defp respond(conn, result, _format), do: json(conn, result)

  defp build_attrs(project_id, params) do
    %{project_id: project_id}
    |> maybe_put_top_k(params["top_k"])
    |> maybe_put_types(params["types"])
  end

  defp maybe_put_top_k(attrs, nil), do: attrs
  defp maybe_put_top_k(attrs, value), do: Map.put(attrs, :top_k, String.to_integer(value))

  defp maybe_put_types(attrs, nil), do: attrs

  defp maybe_put_types(attrs, types) when is_list(types),
    do: Map.put(attrs, :types, Enum.map(types, &String.to_existing_atom/1))

  defp maybe_put_types(attrs, type) when is_binary(type),
    do: Map.put(attrs, :types, [String.to_existing_atom(type)])
end
