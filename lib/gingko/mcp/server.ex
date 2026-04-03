defmodule Gingko.MCP.Server do
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
  component(Gingko.MCP.Tools.GetCluster)
  component(Gingko.MCP.Tools.RefreshPrincipalMemory)
  component(Gingko.MCP.Tools.SetCharter)
end
