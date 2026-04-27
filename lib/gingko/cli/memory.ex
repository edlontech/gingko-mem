defmodule Gingko.CLI.Memory do
  @moduledoc """
  Implements the `gingko memory <subcommand>` surface invoked by Claude
  Code skill prompts and hook scripts.

  Returns the desired process exit code (`0` on success, `1` on failure).
  The caller (`Gingko.CLI.Dispatcher`) is responsible for halting the VM
  with that code; this module never calls `System.halt/1` so it stays
  testable.
  """

  alias Gingko.CLI.MemoryClient
  alias Gingko.CLI.ProjectId
  alias Gingko.CLI.SessionFile

  @default_goal "Claude Code session"
  @default_top_k 30

  @spec run(String.t(), [String.t()]) :: 0 | 1
  def run("project-id", []) do
    IO.puts(ProjectId.detect())
    0
  end

  def run("session-id", []) do
    case SessionFile.read(ProjectId.detect()) do
      {:ok, id} -> IO.puts(id)
      :error -> :ok
    end

    0
  end

  def run("ensure-project", []) do
    project_id = ProjectId.detect()

    case MemoryClient.open_project(project_id, []) do
      {:ok, body} ->
        emit_json(body)
        0

      {:error, reason} ->
        warn("ensure-project failed: #{format_error(reason)}")
        0
    end
  end

  def run("start-session", args) do
    goal = List.first(args) || @default_goal
    project_id = ProjectId.detect()

    case MemoryClient.start_session(project_id, %{goal: goal, agent: "claude-code"}, []) do
      {:ok, %{"session_id" => session_id} = body} when is_binary(session_id) ->
        :ok = SessionFile.write(project_id, session_id)
        emit_json(body)
        0

      {:ok, body} ->
        emit_json(body)
        0

      {:error, reason} ->
        warn("start-session failed: #{format_error(reason)}")
        0
    end
  end

  def run("append-step", [observation, action]) do
    project_id = ProjectId.detect()

    case SessionFile.read(project_id) do
      :error ->
        0

      {:ok, session_id} ->
        case MemoryClient.append_step(session_id, observation, action, []) do
          {:ok, body} ->
            emit_json(body)
            0

          {:error, reason} ->
            warn("append-step failed: #{format_error(reason)}")
            0
        end
    end
  end

  def run("close-session", []) do
    project_id = ProjectId.detect()

    case SessionFile.read(project_id) do
      :error ->
        0

      {:ok, session_id} ->
        result =
          case MemoryClient.commit_session(session_id, []) do
            {:ok, body} ->
              emit_json(body)
              0

            {:error, reason} ->
              warn("close-session failed: #{format_error(reason)}")
              0
          end

        SessionFile.clear(project_id)
        result
    end
  end

  def run("recall", [query]) do
    project_id = ProjectId.detect()

    case MemoryClient.recall(project_id, query, []) do
      {:ok, body} ->
        emit_json(body)
        0

      {:error, reason} ->
        warn("recall failed: #{format_error(reason)}")
        0
    end
  end

  def run("get-node", [node_id]) do
    project_id = ProjectId.detect()

    case MemoryClient.get_node(project_id, node_id, []) do
      {:ok, body} ->
        emit_json(body)
        0

      {:error, reason} ->
        warn("get-node failed: #{format_error(reason)}")
        0
    end
  end

  def run("latest-memories", args) do
    fetch_latest(parse_top_k(args), :json)
  end

  def run("latest-memories-md", args) do
    fetch_latest(parse_top_k(args), :markdown)
  end

  def run("session-primer", []) do
    project_id = ProjectId.detect()

    case MemoryClient.session_primer(project_id, []) do
      {:ok, body} ->
        emit_json(body)
        0

      {:error, reason} ->
        warn("session-primer failed: #{format_error(reason)}")
        0
    end
  end

  def run("summaries-enabled", []) do
    case MemoryClient.summaries_status([]) do
      {:ok, _} -> 0
      {:error, _} -> 1
    end
  end

  def run("status", []) do
    case MemoryClient.health([]) do
      {:ok, _} ->
        IO.puts("Gingko reachable at #{MemoryClient.base_url()}")
        0

      {:error, _} ->
        1
    end
  end

  def run("help", _) do
    print_help()
    0
  end

  def run(cmd, _args) do
    warn("unknown memory subcommand: #{cmd}")
    print_help()
    1
  end

  @spec print_help() :: :ok
  def print_help do
    IO.puts("""
    Usage: gingko memory <command> [args]

    Commands:
      project-id              Derive project ID from git remote
      session-id              Print the active session id (empty when none)
      ensure-project          Open/ensure project exists
      start-session [goal]    Start a new memory session (default goal: "#{@default_goal}")
      append-step <obs> <act> Append a step to the current session
      close-session           Commit and close the current session
      recall <query>          Search project memories
      get-node <node_id>      Get a specific node
      latest-memories [k]     Get latest memories as JSON (default #{@default_top_k})
      latest-memories-md [k]  Get latest memories as markdown (default #{@default_top_k})
      session-primer          Fetch the composed session primer document
      summaries-enabled       Exit 0 if summaries feature is enabled, 1 otherwise
      status                  Exit 0 if Gingko service is reachable, 1 otherwise
    """)
  end

  defp fetch_latest(top_k, format) do
    project_id = ProjectId.detect()

    case MemoryClient.latest_memories(project_id, top_k, format, []) do
      {:ok, body} ->
        emit_json(body)
        0

      {:error, reason} ->
        warn("latest-memories failed: #{format_error(reason)}")
        0
    end
  end

  defp parse_top_k([]), do: @default_top_k

  defp parse_top_k([raw | _]) do
    case Integer.parse(raw) do
      {int, ""} when int > 0 -> int
      _ -> @default_top_k
    end
  end

  defp emit_json(body) do
    IO.puts(Jason.encode!(body))
  end

  defp warn(message) do
    IO.puts(:stderr, "[gingko] #{message}")
  end

  defp format_error({:status, code, body}), do: "status #{code}: #{inspect(body)}"
  defp format_error(other), do: inspect(other)
end
