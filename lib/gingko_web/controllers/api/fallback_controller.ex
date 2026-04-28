defmodule GingkoWeb.Api.FallbackController do
  @moduledoc false

  use GingkoWeb, :controller

  require Logger

  def call(conn, {:error, %{code: :project_not_open} = error}) do
    conn |> put_status(:not_found) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %{code: :session_not_found} = error}) do
    conn |> put_status(:not_found) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %{code: :project_registration_failed} = error}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %{code: :invalid_session_state} = error}) do
    conn |> put_status(:conflict) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %{code: :invalid_params} = error}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %{code: :node_not_found} = error}) do
    conn |> put_status(:not_found) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %{code: :cluster_not_found} = error}) do
    conn |> put_status(:not_found) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %{code: :charter_locked} = error}) do
    conn |> put_status(:conflict) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: :validation_failed, errors: translate_changeset(changeset)}})
  end

  def call(conn, {:error, %{code: _} = error}) do
    Logger.error("api error on #{conn.method} #{conn.request_path}: #{inspect(error)}")
    conn |> put_status(:internal_server_error) |> json(%{error: error_body(error)})
  end

  def call(conn, {:error, reason}) do
    Logger.error(
      "unexpected api error on #{conn.method} #{conn.request_path}: #{inspect(reason)}"
    )

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: %{code: :unexpected_error, message: inspect(reason)}})
  end

  defp error_body(%{code: code, message: message}), do: %{code: code, message: message}

  defp translate_changeset(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
