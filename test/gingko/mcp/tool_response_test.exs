defmodule Gingko.MCP.ToolResponseTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Gingko.MCP.ToolResponse
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory

  test "serializes struct payloads before returning them" do
    frame = Frame.new()

    {:reply, response, _frame} =
      ToolResponse.from_result({:ok, %ReasonedMemory{semantic: "summary"}}, frame)

    assert %{"semantic" => "summary"} = response.structured_content
  end

  test "preserves nil values and serializes datetimes in nested payloads" do
    frame = Frame.new()
    created_at = ~U[2026-03-16 12:00:00Z]

    {:reply, response, _frame} =
      ToolResponse.from_result(
        {:ok, %{node: nil, metadata: %{created_at: created_at}}},
        frame
      )

    assert %{
             "node" => nil,
             "metadata" => %{"created_at" => "2026-03-16T12:00:00Z"}
           } = response.structured_content
  end
end
