defmodule GingkoWeb.Api.MaintenanceController do
  use GingkoWeb, :controller

  action_fallback GingkoWeb.Api.FallbackController

  @valid_operations ~w(decay consolidate validate)

  def create(conn, %{"project_id" => project_id, "operation" => operation})
      when operation in @valid_operations do
    with {:ok, result} <-
           Gingko.Memory.run_maintenance(%{
             project_id: project_id,
             operation: String.to_existing_atom(operation)
           }) do
      conn
      |> put_status(:accepted)
      |> json(result)
    end
  end

  def create(conn, %{"operation" => _operation}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "operation must be one of: #{Enum.join(@valid_operations, ", ")}"})
  end
end
