defmodule Gingko.CLI.Remote do
  @moduledoc """
  Prints a ready-to-run `erl -remsh` incantation for attaching an
  interactive remote shell to the running Gingko node.

  BEAM processes can't replace themselves with `execve`, so we can't
  give a spawned `erl` the user's TTY. The pragmatic answer is to emit
  the exact command to run from the user's shell.
  """

  alias Gingko.CLI.Cookie
  alias Gingko.CLI.NodeOps
  alias Gingko.CLI.Paths

  @spec run() :: :ok | {:error, term()}
  def run do
    with {:ok, _target} <- NodeOps.ping(),
         erl when is_binary(erl) <- Paths.erl_executable() do
      cookie = Cookie.read_or_generate!()
      cli_name = "cli-#{System.unique_integer([:positive])}@127.0.0.1"
      target = Paths.node_name()

      command = [
        erl,
        "-name",
        cli_name,
        "-setcookie",
        Atom.to_string(cookie),
        "-remsh",
        Atom.to_string(target),
        "-hidden"
      ]

      header =
        Owl.Data.tag(
          "Run the following to attach a remote IEx shell to the running Gingko node:",
          :cyan
        )

      Owl.IO.puts(header)
      Owl.IO.puts("")
      Owl.IO.puts(Owl.Data.tag(Enum.map_join(command, " ", &shell_quote/1), :bright))
      Owl.IO.puts("")

      Owl.IO.puts(
        Owl.Data.tag(
          "(BEAM-hosted CLIs can't hand off the TTY directly, so we emit the command instead.)",
          :light_black
        )
      )

      :ok
    else
      {:error, :not_running} -> {:error, :not_running}
      nil -> {:error, :erl_not_found}
    end
  end

  defp shell_quote(arg) do
    if String.match?(arg, ~r/[^A-Za-z0-9_\-.\/@:=]/) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end
end
