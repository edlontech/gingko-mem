defmodule Gingko.MCP.Server do
  @moduledoc """
  Anubis MCP server entrypoint for Gingko. Declares the public set of memory
  tools that external agents can invoke over the `/mcp` HTTP transport,
  spanning the write flow (`open_project_memory` -> `start_session` ->
  `append_step` -> `commit_session` / `close_async`) and the read flow
  (`recall`, `get_node`, `get_session_state`, `list_projects`,
  `latest_memories`, `get_session_primer`), along with the maintenance and
  charter operations.
  """
  use Anubis.Server,
    name: "gingko",
    version: "0.1.0",
    capabilities: [:tools]

  component(Gingko.MCP.Tools.OpenProjectMemory)
  component(Gingko.MCP.Tools.StartSession)
  component(Gingko.MCP.Tools.AppendStep)
  component(Gingko.MCP.Tools.CommitSession)
  component(Gingko.MCP.Tools.CloseAndCommit)
  component(Gingko.MCP.Tools.Recall)
  component(Gingko.MCP.Tools.GetNode)
  component(Gingko.MCP.Tools.GetSessionState)
  component(Gingko.MCP.Tools.ListProjects)
  component(Gingko.MCP.Tools.LatestMemories)
  component(Gingko.MCP.Tools.RunMaintenance)
  component(Gingko.MCP.Tools.GetSessionPrimer)
  component(Gingko.MCP.Tools.RefreshPrincipalMemory)
  component(Gingko.MCP.Tools.SetCharter)
end
