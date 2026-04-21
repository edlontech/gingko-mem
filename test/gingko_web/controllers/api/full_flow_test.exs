defmodule GingkoWeb.Api.FullFlowTest do
  use GingkoWeb.ConnCase, async: false
  use Mimic

  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory
  alias Mnemosyne.Pipeline.RecallResult

  setup :set_mimic_global

  setup do
    Mimic.copy(Mnemosyne)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat, fn msgs, _opts ->
      prompt =
        Enum.find_value(msgs, "", fn
          %{role: :system, content: content} -> content
          _ -> nil
        end)

      content =
        cond do
          String.contains?(prompt, "identify the specific sub-goal") ->
            "Test the REST API"

          String.contains?(prompt, "rate how well this action serves the sub-goal") ->
            "0.9"

          String.contains?(prompt, "provide a concise summary of the current environment state") ->
            "The REST API is working correctly."

          true ->
            "mock response"
        end

      {:ok, %Mnemosyne.LLM.Response{content: content, model: "mock:test", usage: %{}}}
    end)

    stub(Gingko.TestSupport.Mnemosyne.MockLLM, :chat_structured, fn msgs, _schema, _opts ->
      prompt =
        Enum.find_value(msgs, "", fn
          %{role: :system, content: content} -> content
          _ -> nil
        end)

      content =
        cond do
          String.contains?(prompt, "extracting factual knowledge from agent experiences") ->
            %{
              facts: [
                %{
                  proposition: "The REST API works correctly.",
                  concepts: ["REST", "API"]
                }
              ]
            }

          String.contains?(prompt, "extracting actionable instructions from agent experiences") ->
            %{
              instructions: [
                %{
                  intent: "Verify API endpoints",
                  condition: "When testing REST API",
                  instruction: "Test all endpoints end to end.",
                  expected_outcome: "All endpoints return expected responses."
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
    end)

    :ok
  end

  @tag capture_log: true
  test "full write and read flow via REST API", %{conn: conn} do
    project_id = "api-flow-test-" <> Integer.to_string(System.unique_integer([:positive]))

    on_exit(fn ->
      repo_id = Gingko.Memory.ProjectRegistry.resolve(project_id).repo_id
      if repo_id in Mnemosyne.list_repos(), do: Mnemosyne.close_repo(repo_id)
    end)

    conn = post(conn, "/api/projects/#{project_id}/open")
    assert %{"project_id" => ^project_id, "already_open" => false} = json_response(conn, 200)

    conn = get(build_conn(), "/api/projects")
    projects = json_response(conn, 200)["projects"]
    assert Enum.any?(projects, &(&1["project_id"] == project_id))

    conn =
      post(build_conn(), "/api/projects/#{project_id}/sessions", %{
        "goal" => "test the REST API",
        "agent" => "test-agent"
      })

    session = json_response(conn, 201)
    session_id = session["session_id"]
    assert session["state"] == "collecting"

    conn = get(build_conn(), "/api/sessions/#{session_id}/state")
    assert json_response(conn, 200)["state"] == "collecting"

    conn =
      post(build_conn(), "/api/sessions/#{session_id}/steps", %{
        "observation" => "the REST API works",
        "action" => "verified all endpoints"
      })

    assert json_response(conn, 202)["session_id"] == session_id

    conn = post(build_conn(), "/api/sessions/#{session_id}/commit")
    assert json_response(conn, 200)["state"] == "closing"

    stub(Mnemosyne, :recall, fn _repo_id, _query ->
      {:ok, %RecallResult{reasoned: %ReasonedMemory{semantic: "test summary"}, touched_nodes: []}}
    end)

    conn = get build_conn(), "/api/projects/#{project_id}/recall", %{"query" => "REST API"}
    body = json_response(conn, 200)
    assert body["project_id"] == project_id
    assert is_map(body["memory"])
  end
end
