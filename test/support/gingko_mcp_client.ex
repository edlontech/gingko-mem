defmodule Gingko.TestSupport.GingkoMCPClient do
  use Anubis.Client,
    name: "gingko-test-client",
    version: "0.1.0",
    protocol_version: "2025-03-26",
    capabilities: []
end
