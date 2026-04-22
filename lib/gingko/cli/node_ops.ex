defmodule Gingko.CLI.NodeOps do
  @moduledoc """
  Distributed Erlang operations against a running Gingko node.

  This module is invoked from a short-lived CLI BEAM. It starts
  distribution locally (hidden node, random name), sets the shared
  cookie, and RPCs the target node.
  """

  alias Gingko.CLI.Cookie
  alias Gingko.CLI.Paths

  @connect_timeout 2_000

  @typep connected :: {:ok, node()}
  @typep not_running :: {:error, :not_running}

  @spec ping() :: connected() | not_running()
  def ping do
    target = Paths.node_name()

    with :ok <- ensure_distribution(),
         :pong <- Node.ping(target) do
      {:ok, target}
    else
      :pang -> {:error, :not_running}
      {:error, _} = error -> error
    end
  end

  @spec stop() :: :ok | not_running()
  def stop do
    with {:ok, target} <- ping() do
      _ = :rpc.call(target, :init, :stop, [], @connect_timeout)
      :ok
    end
  end

  @spec pid() :: {:ok, String.t()} | not_running()
  def pid do
    with {:ok, target} <- ping() do
      case :rpc.call(target, System, :pid, [], @connect_timeout) do
        pid when is_binary(pid) -> {:ok, pid}
        {:badrpc, reason} -> {:error, {:rpc, reason}}
      end
    end
  end

  @spec rpc(String.t()) :: {:ok, term()} | {:error, term()} | not_running()
  def rpc(expr) when is_binary(expr) do
    with {:ok, target} <- ping() do
      case :rpc.call(target, Code, :eval_string, [expr], @connect_timeout) do
        {:badrpc, reason} -> {:error, {:rpc, reason}}
        {value, _bindings} -> {:ok, value}
      end
    end
  end

  @spec status() ::
          {:ok, %{node: node(), pid: String.t(), uptime_ms: non_neg_integer()}} | not_running()
  def status do
    with {:ok, target} <- ping() do
      pid = :rpc.call(target, System, :pid, [], @connect_timeout)
      uptime_ms = :rpc.call(target, :erlang, :statistics, [:wall_clock], @connect_timeout)

      uptime =
        case uptime_ms do
          {total, _since_last} -> total
          _ -> 0
        end

      {:ok, %{node: target, pid: pid, uptime_ms: uptime}}
    end
  end

  @doc """
  Starts distributed Erlang in the current BEAM as a hidden CLI node.
  Safe to call repeatedly.
  """
  @spec ensure_distribution() :: :ok | {:error, term()}
  def ensure_distribution do
    cookie = Cookie.read_or_generate!()

    case Node.alive?() do
      true ->
        :erlang.set_cookie(Node.self(), cookie)
        :ok

      false ->
        name = :"cli-#{System.unique_integer([:positive])}@127.0.0.1"

        case Node.start(name, name_domain: :longnames) do
          {:ok, _} ->
            :erlang.set_cookie(Node.self(), cookie)
            :ok

          {:error, _} = error ->
            error
        end
    end
  end
end
