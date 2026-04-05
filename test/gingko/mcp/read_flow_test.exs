defmodule Gingko.MCP.ReadFlowTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Graph.Changeset
  alias Mnemosyne.Graph.Node.Semantic
  alias Mnemosyne.Graph.Node.Tag
  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult

  @port 4003

  setup :set_mimic_global

  setup_all do
    start_supervised!({Bandit, plug: GingkoWeb.Endpoint, port: @port})
    :ok
  end

  setup do
    Mimic.copy(Mnemosyne)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, &mock_chat/2)
    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, &mock_chat_structured/3)

    start_supervised!(
      {Gingko.TestSupport.GingkoMCPClient,
       transport: {:streamable_http, base_url: "http://localhost:#{@port}", mcp_path: "/mcp"}}
    )

    wait_for_client_handshake!()

    :ok
  end

  test "lists the read tools" do
    assert {:ok, response} = Gingko.TestSupport.GingkoMCPClient.list_tools()

    names =
      response.result["tools"]
      |> Enum.map(& &1["name"])

    assert "recall" in names
    assert "get_node" in names
    assert "get_session_state" in names
    assert "list_projects" in names
  end

  test "list_projects returns opened projects" do
    project_id = unique_project_id()

    assert {:ok, _response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("open_project_memory", %{
               project_id: project_id
             })

    assert {:ok, response} = Gingko.TestSupport.GingkoMCPClient.call_tool("list_projects", %{})

    assert %{"projects" => projects} = response.result["structuredContent"]

    assert Enum.any?(projects, fn %{"project_id" => listed_project_id, "repo_id" => _repo_id} ->
             listed_project_id == project_id
           end)
  end

  test "list_projects keeps registered projects after their repo is closed" do
    project_id = unique_project_id()

    open_project!(project_id)

    repo_id = Gingko.Memory.ProjectRegistry.repo_id(project_id)
    assert :ok = Mnemosyne.close_repo(repo_id)

    assert {:ok, response} = Gingko.TestSupport.GingkoMCPClient.call_tool("list_projects", %{})
    assert %{"projects" => projects} = response.result["structuredContent"]

    assert Enum.any?(projects, fn %{"project_id" => listed_project_id} ->
             listed_project_id == project_id
           end)
  end

  test "get_session_state reports collecting then transitions after close_async" do
    project_id = unique_project_id()
    open_project!(project_id)

    assert {:ok, session_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("start_session", %{
               project_id: project_id,
               goal: "Track session lifecycle",
               agent: "codex",
               thread_id: "thread-state"
             })

    session_id = session_response.result["structuredContent"]["session_id"]

    assert {:ok, collecting_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("get_session_state", %{
               session_id: session_id
             })

    assert %{"state" => "collecting"} = collecting_response.result["structuredContent"]

    assert {:ok, _close_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("close_async", %{
               session_id: session_id
             })

    assert {:ok, post_close_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("get_session_state", %{
               session_id: session_id
             })

    post_close_state = post_close_response.result["structuredContent"]["state"]
    assert post_close_state in ["extracting", "ready", "idle"]
  end

  @tag capture_log: true
  test "recall returns serialized memory after commit" do
    project_id = unique_project_id()
    open_project!(project_id)

    stub(Mnemosyne, :recall, fn repo_id, query ->
      assert repo_id == Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      assert query == "What did we decide?"

      {:ok,
       %RecallResult{
         reasoned: %ReasonedMemory{
           semantic: "Project memory is stored in a Mnemosyne-backed repo."
         },
         touched_nodes: []
       }}
    end)

    assert {:ok, session_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("start_session", %{
               project_id: project_id,
               goal: "Remember architecture decisions",
               agent: "codex",
               thread_id: "thread-recall"
             })

    session_id = session_response.result["structuredContent"]["session_id"]

    assert {:ok, _append_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("append_step", %{
               session_id: session_id,
               observation: "Need a stable project memory boundary",
               action: "Implemented Gingko.Memory over Mnemosyne"
             })

    assert {:ok, _close_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("close_async", %{
               session_id: session_id
             })

    assert {:ok, recall_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("recall", %{
               project_id: project_id,
               query: "What did we decide?"
             })

    assert %{
             "project_id" => ^project_id,
             "query" => "What did we decide?",
             "session_id" => nil,
             "touched_node_ids" => [],
             "memory" => %{
               "episodic" => nil,
               "semantic" => "Project memory is stored in a Mnemosyne-backed repo.",
               "procedural" => nil
             }
           } = recall_response.result["structuredContent"]
  end

  test "recall returns a structured domain error when the project is unopened" do
    assert {:ok, response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("recall", %{
               project_id: unique_project_id(),
               query: "What happened?"
             })

    assert response.is_error

    assert %{
             "error" => %{
               "code" => "project_not_open",
               "id" => _repo_id,
               "message" => "project repo is not open"
             }
           } = response.result["structuredContent"]
  end

  test "get_node returns serialized node payload for known ids" do
    project_id = unique_project_id()
    open_project!(project_id)
    repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id

    changeset =
      Changeset.new()
      |> Changeset.add_node(%Tag{id: "tag-1", label: "elixir"})
      |> Changeset.add_node(%Semantic{
        id: "sem-1",
        proposition: "Elixir is functional",
        confidence: 0.9
      })
      |> Changeset.add_link("sem-1", "tag-1", :membership)
      |> Changeset.put_metadata("sem-1", NodeMetadata.new(access_count: 3))

    :ok = Mnemosyne.apply_changeset(repo_id, changeset)

    eventually(fn ->
      assert {:ok, response} =
               Gingko.TestSupport.GingkoMCPClient.call_tool("get_node", %{
                 project_id: project_id,
                 node_id: "sem-1"
               })

      assert %{
               "project_id" => ^project_id,
               "node_id" => "sem-1",
               "node" => %{
                 "id" => "sem-1",
                 "type" => "semantic",
                 "proposition" => "Elixir is functional",
                 "confidence" => 0.9
               },
               "metadata" => %{"access_count" => 3},
               "linked_nodes" => [%{"id" => "tag-1", "type" => "tag", "label" => "elixir"}]
             } = response.result["structuredContent"]
    end)
  end

  test "get_node returns nil payload when node is unknown" do
    project_id = unique_project_id()
    open_project!(project_id)

    assert {:ok, response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("get_node", %{
               project_id: project_id,
               node_id: "missing"
             })

    assert %{
             "project_id" => ^project_id,
             "node_id" => "missing",
             "node" => nil,
             "metadata" => nil,
             "linked_nodes" => []
           } = response.result["structuredContent"]
  end

  test "get_session_state returns a structured session_not_found error for unknown sessions" do
    assert {:ok, response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("get_session_state", %{
               session_id: "session-missing"
             })

    assert response.is_error

    assert %{
             "error" => %{
               "code" => "session_not_found",
               "id" => "session-missing",
               "message" => "session was not found"
             }
           } = response.result["structuredContent"]
  end

  defp open_project!(project_id) do
    assert {:ok, _response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("open_project_memory", %{
               project_id: project_id
             })
  end

  defp unique_project_id do
    "mcp-read-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp mock_chat(messages, _opts) do
    prompt = system_prompt(messages)

    content =
      cond do
        String.contains?(prompt, "identify the specific sub-goal") ->
          "Persist project memory safely"

        String.contains?(prompt, "rate how well this action serves the sub-goal") ->
          "0.9"

        String.contains?(prompt, "provide a concise summary of the current environment state") ->
          "The project now has an open repo and is appending memory-relevant steps."

        String.contains?(prompt, "compute a single return value") ->
          "0.85"

        true ->
          "mock response"
      end

    {:ok, %Mnemosyne.LLM.Response{content: content, model: "mock:test", usage: %{}}}
  end

  defp mock_chat_structured(messages, _schema, _opts) do
    prompt = system_prompt(messages)

    content =
      cond do
        String.contains?(prompt, "extracting factual knowledge from agent experiences") ->
          %{
            facts: [
              %{
                proposition: "Project memory is stored in a Mnemosyne-backed repo.",
                concepts: ["project memory", "mnemosyne"]
              }
            ]
          }

        String.contains?(prompt, "extracting actionable instructions from agent experiences") ->
          %{
            instructions: [
              %{
                intent: "Persist project memory",
                condition: "When a session contains memory-worthy steps",
                instruction: "Close the session and commit it through Mnemosyne.",
                expected_outcome: "The session becomes durable project memory."
              }
            ]
          }

        true ->
          %{}
      end

    {:ok, %Mnemosyne.LLM.Response{content: content, model: "mock:test", usage: %{}}}
  end

  defp system_prompt(messages) do
    Enum.find_value(messages, "", fn
      %{role: :system, content: content} -> content
      _ -> nil
    end)
  end

  defp wait_for_client_handshake!(attempts \\ 20)

  defp wait_for_client_handshake!(0) do
    flunk("Timed out waiting for MCP client handshake")
  end

  defp wait_for_client_handshake!(attempts) do
    if Gingko.TestSupport.GingkoMCPClient.get_server_capabilities() do
      :ok
    else
      Process.sleep(50)
      wait_for_client_handshake!(attempts - 1)
    end
  end

  defp eventually(fun, retries \\ 50)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(fun, retries - 1)
  end
end
