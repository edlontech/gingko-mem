defmodule Gingko.ObservabilityFlowTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory

  @port 4004

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

  @tag :skip
  test "mcp write and recall activity appears in project monitor snapshot" do
    project_id = unique_project_id()
    query = "what changed?"

    on_exit(fn -> close_project_if_open(project_id) end)

    stub(Mnemosyne, :recall, fn repo_id, ^query ->
      assert repo_id == Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      result = {:ok, %ReasonedMemory{semantic: "observability result"}}
      :ok = Gingko.Memory.Notifier.notify(repo_id, {:recall_executed, query, result, %{}})
      result
    end)

    assert {:ok, _open_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("open_project_memory", %{
               project_id: project_id
             })

    assert {:ok, session_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("start_session", %{
               project_id: project_id,
               goal: "Track observability",
               agent: "codex",
               thread_id: "thread-observability"
             })

    session_id = session_response.result["structuredContent"]["session_id"]

    assert {:ok, _append_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("append_step", %{
               session_id: session_id,
               observation: "Need monitor visibility",
               action: "Commit and validate project snapshot"
             })

    assert {:ok, _close_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("close_async", %{
               session_id: session_id
             })

    assert {:ok, recall_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("recall", %{
               project_id: project_id,
               query: query
             })

    refute recall_response.is_error

    eventually(fn ->
      snapshot = Gingko.Memory.project_monitor_snapshot(project_id)

      assert snapshot.project_id == project_id
      assert snapshot.active_sessions == []
      assert Enum.any?(snapshot.recent_events, &(&1.type == :session_started))

      assert Enum.any?(
               snapshot.recent_events,
               &(&1.type in [:session_committed, :changeset_applied])
             )

      assert snapshot.counters.recent_recalls >= 1
      assert Enum.any?(snapshot.recent_events, &(&1.type == :recall_executed))
    end)
  end

  test "mcp write flow completes successfully" do
    project_id = unique_project_id()

    on_exit(fn -> close_project_if_open(project_id) end)

    assert {:ok, _open_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("open_project_memory", %{
               project_id: project_id
             })

    assert {:ok, session_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("start_session", %{
               project_id: project_id,
               goal: "Verify write isolation",
               agent: "codex",
               thread_id: "thread-failure-isolation"
             })

    session_id = session_response.result["structuredContent"]["session_id"]

    assert {:ok, _append_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("append_step", %{
               session_id: session_id,
               observation: "Test write flow",
               action: "Write flow should succeed"
             })

    assert {:ok, close_response} =
             Gingko.TestSupport.GingkoMCPClient.call_tool("close_async", %{
               session_id: session_id
             })

    assert close_response.result["structuredContent"]["state"] in ["closing", :closing]
  end

  defp unique_project_id do
    "mcp-observe-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp close_project_if_open(project_id) do
    repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
    if repo_id in Mnemosyne.list_repos(), do: :ok = Mnemosyne.close_repo(repo_id)
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

  defp eventually(fun, retries \\ 300)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, retries - 1)
  end
end
