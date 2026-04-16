defmodule Gingko.Summaries.PlaybookTest do
  use ExUnit.Case, async: true

  alias Gingko.Summaries.Playbook

  @required_tool_names ~w(recall get_cluster get_node latest_memories append_step get_session_primer)

  test "mentions every current MCP tool name" do
    md = Playbook.markdown()

    for name <- @required_tool_names do
      assert md =~ name, "playbook is missing reference to MCP tool `#{name}`"
    end
  end

  test "is non-empty and starts with a heading" do
    md = Playbook.markdown()
    assert String.starts_with?(md, "# ")
    assert byte_size(md) > 300
  end
end
