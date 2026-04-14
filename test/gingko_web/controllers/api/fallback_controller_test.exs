defmodule GingkoWeb.Api.FallbackControllerTest do
  use GingkoWeb.ConnCase, async: true

  alias GingkoWeb.Api.FallbackController

  test "project_not_open returns 404", %{conn: conn} do
    conn =
      FallbackController.call(conn, {:error, %{code: :project_not_open, message: "not open"}})

    assert json_response(conn, 404)["error"]["code"] == "project_not_open"
  end

  test "session_not_found returns 404", %{conn: conn} do
    conn =
      FallbackController.call(conn, {:error, %{code: :session_not_found, message: "not found"}})

    assert json_response(conn, 404)["error"]["code"] == "session_not_found"
  end

  test "project_registration_failed returns 422", %{conn: conn} do
    conn =
      FallbackController.call(
        conn,
        {:error, %{code: :project_registration_failed, message: "bad"}}
      )

    assert json_response(conn, 422)["error"]["code"] == "project_registration_failed"
  end

  test "invalid_session_state returns 409", %{conn: conn} do
    conn =
      FallbackController.call(
        conn,
        {:error, %{code: :invalid_session_state, message: "wrong state"}}
      )

    assert json_response(conn, 409)["error"]["code"] == "invalid_session_state"
  end

  test "invalid_params returns 422", %{conn: conn} do
    conn =
      FallbackController.call(conn, {:error, %{code: :invalid_params, message: "missing goal"}})

    assert json_response(conn, 422)["error"]["code"] == "invalid_params"
  end

  test "unknown error code returns 500", %{conn: conn} do
    conn =
      FallbackController.call(conn, {:error, %{code: :memory_operation_failed, message: "boom"}})

    assert json_response(conn, 500)["error"]["code"] == "memory_operation_failed"
  end

  test "Ecto.Changeset error returns 422 validation_failed", %{conn: conn} do
    changeset =
      %Gingko.Summaries.PrincipalMemorySection{}
      |> Gingko.Summaries.PrincipalMemorySection.changeset(%{
        project_key: "p",
        kind: "not_a_kind"
      })

    refute changeset.valid?

    conn = FallbackController.call(conn, {:error, changeset})
    body = json_response(conn, 422)

    assert body["error"]["code"] == "validation_failed"
    assert is_map(body["error"]["errors"])
    assert body["error"]["errors"]["kind"] |> is_list()
  end
end
