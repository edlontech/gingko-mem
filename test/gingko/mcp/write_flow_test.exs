defmodule Gingko.MCP.WriteFlowTest do
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  setup_all do
    start_supervised!({Bandit, plug: GingkoWeb.Endpoint, port: 4002})
    :ok
  end

  setup do
    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, &mock_chat/2)
    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, &mock_chat_structured/3)

    start_supervised!(
      {Gingko.TestSupport.GingkoMCPClient,
       transport: {:streamable_http, base_url: "http://localhost:4002", mcp_path: "/mcp"}}
    )

    wait_for_client_handshake!()

    :ok
  end

  test "lists the thin write tools" do
    assert {:ok, response} = Gingko.TestSupport.GingkoMCPClient.list_tools()

    tools = response.result["tools"]
    names = Enum.map(tools, & &1["name"])
    assert "open_project_memory" in names
    assert "start_session" in names
    assert "append_step" in names
    assert "close_async" in names
  end

  @tag capture_log: true
  test "runs the full MCP write flow" do
    project_id = "mcp-test-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, project_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("open_project_memory", %{
               project_id: project_id
             })

    project = project_response.result["structuredContent"]
    assert project["project_id"] == project_id

    assert {:ok, session_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("start_session", %{
               project_id: project_id,
               goal: "Remember architecture decisions",
               agent: "codex",
               thread_id: "thread-123"
             })

    session = session_response.result["structuredContent"]

    assert {:ok, _} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("append_step", %{
               session_id: session["session_id"],
               observation: "Need a stable project memory boundary",
               action: "Implemented Gingko.Memory over Mnemosyne"
             })

    assert {:ok, result_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("close_async", %{
               session_id: session["session_id"]
             })

    result = result_response.result["structuredContent"]
    assert result["state"] in ["closing", :closing]
  end

  test "start_session returns a structured domain error when the project is unopened" do
    project_id = "mcp-test-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("start_session", %{
               project_id: project_id,
               goal: "Remember architecture decisions",
               agent: "codex",
               thread_id: "thread-123"
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

        String.contains?(prompt, "evaluating prescription quality") ->
          %{
            scores: [
              %{index: 0, return_score: 0.85}
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
end
