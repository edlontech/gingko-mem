defmodule Gingko.MCP.Tools.RefreshPrincipalMemory do
  @moduledoc """
  MCP tool that triggers on-demand regeneration of principal-memory artifacts,
  bypassing the automatic debounce and dirty-tracker thresholds.
  """

  use Anubis.Server.Component, type: :tool

  alias Gingko.MCP.ToolResponse
  alias Gingko.Summaries.Refresh

  def name, do: "refresh_principal_memory"

  def description do
    """
    Enqueue an on-demand regeneration of principal memory. Use `scope = "state"` \
    to refresh only the project state summary, `scope = "cluster"` together with \
    `cluster_slug` to refresh a single cluster, or `scope = "all"` (default) to \
    refresh the project state and every cluster in the project. Bypasses the \
    normal debounce and dirty-tracker thresholds.
    """
  end

  schema do
    field(:project_id, :string, required: true, description: "The project identifier.")

    field(:scope, :string, description: ~s|One of "all" (default), "state", or "cluster".|)

    field(:cluster_slug, :string,
      description: "Cluster slug. Required when `scope` is `cluster`."
    )
  end

  def execute(args, frame) do
    project_id = args[:project_id] || args["project_id"]
    scope = args[:scope] || args["scope"]
    cluster_slug = args[:cluster_slug] || args["cluster_slug"]

    project_id
    |> Refresh.run(scope, cluster_slug)
    |> ToolResponse.from_result(frame)
  end
end
