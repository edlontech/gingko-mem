defmodule GingkoWeb.Api.CharterController do
  @moduledoc false

  use GingkoWeb, :controller

  alias Gingko.Summaries
  alias Gingko.Summaries.PrincipalMemorySection

  action_fallback GingkoWeb.Api.FallbackController

  def update(conn, %{"project_id" => project_id, "content" => content}) do
    with {:ok, section} <- Summaries.set_charter(project_id, content) do
      json(conn, serialize(section))
    end
  end

  def update(_conn, %{"project_id" => _project_id}) do
    {:error, %{code: :invalid_params, message: "`content` is required"}}
  end

  defp serialize(%PrincipalMemorySection{} = section) do
    section |> Map.from_struct() |> Map.drop([:__meta__])
  end
end
