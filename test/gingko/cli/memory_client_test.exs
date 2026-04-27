defmodule Gingko.CLI.MemoryClientTest do
  use ExUnit.Case, async: true

  alias Gingko.CLI.MemoryClient

  describe "base_url/0" do
    test "defaults to localhost:8008 when GINGKO_URL is unset" do
      original = System.get_env("GINGKO_URL")
      System.delete_env("GINGKO_URL")

      try do
        assert MemoryClient.base_url() == "http://127.0.0.1:8008"
      after
        if original, do: System.put_env("GINGKO_URL", original)
      end
    end

    test "honours GINGKO_URL when set" do
      original = System.get_env("GINGKO_URL")
      System.put_env("GINGKO_URL", "http://example.test:9000")

      try do
        assert MemoryClient.base_url() == "http://example.test:9000"
      after
        if original,
          do: System.put_env("GINGKO_URL", original),
          else: System.delete_env("GINGKO_URL")
      end
    end
  end

  describe "health/1" do
    test "GETs /health" do
      plug =
        expect(fn conn ->
          assert conn.method == "GET"
          assert conn.request_path == "/health"
          json_resp(conn, 200, %{status: "ok", version: "0.1.0"})
        end)

      assert {:ok, %{"status" => "ok"}} = MemoryClient.health(plug: plug)
    end

    test "surfaces non-2xx as {:error, {:status, ...}}" do
      plug = expect(fn conn -> json_resp(conn, 500, %{error: "boom"}) end)
      assert {:error, {:status, 500, %{"error" => "boom"}}} = MemoryClient.health(plug: plug)
    end
  end

  describe "open_project/2" do
    test "POSTs an empty body to /api/projects/:id/open" do
      plug =
        expect(fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/api/projects/edlontech--gingko/open"
          {body, conn} = read_json(conn)
          assert body == %{}
          json_resp(conn, 200, %{project_id: "edlontech--gingko", already_open: false})
        end)

      assert {:ok, %{"project_id" => "edlontech--gingko"}} =
               MemoryClient.open_project("edlontech--gingko", plug: plug)
    end

    test "URL-encodes special characters in the project id" do
      plug =
        expect(fn conn ->
          assert conn.request_path == "/api/projects/foo%20bar/open"
          json_resp(conn, 200, %{})
        end)

      assert {:ok, _} = MemoryClient.open_project("foo bar", plug: plug)
    end
  end

  describe "start_session/3" do
    test "POSTs the session payload" do
      plug =
        expect(fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/api/projects/p1/sessions"
          {body, conn} = read_json(conn)
          assert body == %{"goal" => "Claude Code session", "agent" => "claude-code"}
          json_resp(conn, 201, %{session_id: "sess-1"})
        end)

      assert {:ok, %{"session_id" => "sess-1"}} =
               MemoryClient.start_session(
                 "p1",
                 %{goal: "Claude Code session", agent: "claude-code"},
                 plug: plug
               )
    end
  end

  describe "append_step/4" do
    test "POSTs observation and action to /api/sessions/:sid/steps" do
      plug =
        expect(fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/api/sessions/sess-1/steps"
          {body, conn} = read_json(conn)
          assert body == %{"observation" => "saw X", "action" => "did Y"}
          json_resp(conn, 202, %{accepted: true})
        end)

      assert {:ok, %{"accepted" => true}} =
               MemoryClient.append_step("sess-1", "saw X", "did Y", plug: plug)
    end
  end

  describe "commit_session/2" do
    test "POSTs to /api/sessions/:sid/commit with empty body" do
      plug =
        expect(fn conn ->
          assert conn.method == "POST"
          assert conn.request_path == "/api/sessions/sess-1/commit"
          {body, conn} = read_json(conn)
          assert body == %{}
          json_resp(conn, 200, %{state: "closing"})
        end)

      assert {:ok, %{"state" => "closing"}} = MemoryClient.commit_session("sess-1", plug: plug)
    end
  end

  describe "summarize_session/3" do
    test "POSTs the content payload" do
      plug =
        expect(fn conn ->
          assert conn.request_path == "/api/sessions/sess-1/summarize"
          {body, conn} = read_json(conn)
          assert body == %{"content" => "transcript tail"}
          json_resp(conn, 202, %{summarized: true})
        end)

      assert {:ok, %{"summarized" => true}} =
               MemoryClient.summarize_session("sess-1", "transcript tail", plug: plug)
    end
  end

  describe "recall/3" do
    test "GETs /api/projects/:id/recall with the query parameter" do
      plug =
        expect(fn conn ->
          assert conn.method == "GET"
          assert conn.request_path == "/api/projects/p1/recall"
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params == %{"query" => "auth bug"}
          json_resp(conn, 200, %{matches: []})
        end)

      assert {:ok, %{"matches" => []}} = MemoryClient.recall("p1", "auth bug", plug: plug)
    end
  end

  describe "get_node/3" do
    test "GETs /api/projects/:id/nodes/:nid" do
      plug =
        expect(fn conn ->
          assert conn.request_path == "/api/projects/p1/nodes/node-42"
          json_resp(conn, 200, %{node: %{id: "node-42"}})
        end)

      assert {:ok, %{"node" => %{"id" => "node-42"}}} =
               MemoryClient.get_node("p1", "node-42", plug: plug)
    end
  end

  describe "latest_memories/4" do
    test "defaults to JSON format with top_k=30" do
      plug =
        expect(fn conn ->
          assert conn.request_path == "/api/projects/p1/latest"
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params == %{"top_k" => "30"}
          json_resp(conn, 200, %{memories: []})
        end)

      assert {:ok, %{"memories" => []}} =
               MemoryClient.latest_memories("p1", 30, :json, plug: plug)
    end

    test "passes format=markdown when requested" do
      plug =
        expect(fn conn ->
          conn = Plug.Conn.fetch_query_params(conn)
          assert conn.query_params == %{"top_k" => "100", "format" => "markdown"}
          json_resp(conn, 200, %{format: "markdown", content: "# memories"})
        end)

      assert {:ok, %{"format" => "markdown"}} =
               MemoryClient.latest_memories("p1", 100, :markdown, plug: plug)
    end
  end

  describe "session_primer/2" do
    test "GETs /api/projects/:id/session_primer" do
      plug =
        expect(fn conn ->
          assert conn.method == "GET"
          assert conn.request_path == "/api/projects/p1/session_primer"
          json_resp(conn, 200, %{format: "markdown", content: "## Primer"})
        end)

      assert {:ok, %{"content" => "## Primer"}} = MemoryClient.session_primer("p1", plug: plug)
    end
  end

  describe "summaries_status/1" do
    test "returns {:ok, body} on enabled" do
      plug = expect(fn conn -> json_resp(conn, 200, %{enabled: true}) end)
      assert {:ok, %{"enabled" => true}} = MemoryClient.summaries_status(plug: plug)
    end

    test "returns {:error, {:status, 503, ...}} on disabled" do
      plug = expect(fn conn -> json_resp(conn, 503, %{enabled: false}) end)

      assert {:error, {:status, 503, %{"enabled" => false}}} =
               MemoryClient.summaries_status(plug: plug)
    end
  end

  defp expect(fun), do: fun

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp read_json(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    decoded =
      case body do
        "" -> %{}
        raw -> Jason.decode!(raw)
      end

    {decoded, conn}
  end
end
