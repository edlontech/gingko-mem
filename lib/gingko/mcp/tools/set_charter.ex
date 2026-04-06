defmodule Gingko.MCP.Tools.SetCharter do
  @moduledoc """
  MCP tool that upserts the project charter section. Locked charters are
  protected: the tool refuses to overwrite them.
  """

  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse
  alias Gingko.Summaries

  def name, do: "set_charter"

  def description do
    """
    Upsert the project's charter section. The charter is the human-authored \
    North Star that primes every session alongside the LLM-generated state. \
    If the existing charter row is locked this tool returns `charter_locked` \
    without overwriting.
    """
  end

  schema do
    field(:project_id, :string, required: true, description: "The project identifier.")

    field(:content, :string,
      required: true,
      description: "Markdown charter content. Must be non-empty."
    )
  end

  def execute(args, frame) do
    project_id = args[:project_id] || args["project_id"]
    content = args[:content] || args["content"]

    ToolResponse.from_result(Summaries.set_charter(project_id, content), frame)
  end
end
