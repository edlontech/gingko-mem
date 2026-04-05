defmodule Gingko.MCP.Tools.GetSessionPrimer do
  @moduledoc """
  MCP tool that returns the composed session-primer document for a project.
  """

  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse
  alias Gingko.Summaries

  def name, do: "get_session_primer"

  def description do
    """
    Fetch the composed session primer document: recall playbook + optional charter \
    + project state summary + cluster index + recent memories. Use at session start \
    or to re-orient mid-session.
    """
  end

  schema do
    field(:project_id, :string, required: true, description: "The project to prime.")

    field(:recent_count, :integer,
      description: "Raw-memory tail size. Defaults to the summaries config value."
    )
  end

  def execute(args, frame) do
    project_id = args[:project_id] || args["project_id"]

    with {:ok, opts} <- build_opts(args[:recent_count] || args["recent_count"]),
         {:ok, content} <- Summaries.render_primer(project_id, opts) do
      ToolResponse.from_text(content, frame)
    else
      {:error, reason} -> ToolResponse.from_result({:error, reason}, frame)
    end
  end

  defp build_opts(nil), do: {:ok, []}
  defp build_opts(n) when is_integer(n), do: {:ok, [recent_count: n]}

  defp build_opts(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, ""} ->
        {:ok, [recent_count: int]}

      _ ->
        {:error, %{code: :invalid_params, message: "`recent_count` must be an integer"}}
    end
  end

  defp build_opts(_),
    do: {:error, %{code: :invalid_params, message: "`recent_count` must be an integer"}}
end
