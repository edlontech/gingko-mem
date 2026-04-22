defmodule Gingko.TestSupport.GingkoMCPClient do
  @moduledoc """
  Anubis MCP client used by the test suite to talk to the Gingko server as a
  real agent would. Tests drive it through the standard client API to exercise
  end-to-end flows over the MCP transport.
  """
  use Anubis.Client,
    name: "gingko-test-client",
    version: "0.1.0",
    protocol_version: "2025-03-26",
    capabilities: []
end
