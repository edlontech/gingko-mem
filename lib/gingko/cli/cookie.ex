defmodule Gingko.CLI.Cookie do
  @moduledoc """
  Reads and generates the Erlang distribution cookie shared between the
  running Gingko node and short-lived CLI invocations.

  The cookie lives at `<GINGKO_HOME>/.cookie` with mode 0600. It is
  auto-generated on first boot and preserved across restarts so that
  `gingko stop`, `gingko remote`, and friends can reconnect.
  """

  alias Gingko.CLI.Paths

  @cookie_bytes 24

  @spec read_or_generate!() :: atom()
  def read_or_generate! do
    path = Paths.cookie_file()

    case File.read(path) do
      {:ok, contents} ->
        contents |> String.trim() |> ensure_non_empty!(path) |> String.to_atom()

      {:error, :enoent} ->
        generate_and_write!(path)
    end
  end

  @spec read!() :: atom()
  def read! do
    path = Paths.cookie_file()
    contents = File.read!(path) |> String.trim()
    ensure_non_empty!(contents, path) |> String.to_atom()
  end

  defp generate_and_write!(path) do
    cookie =
      @cookie_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, cookie)
    File.chmod!(path, 0o600)
    String.to_atom(cookie)
  end

  defp ensure_non_empty!("", path), do: raise("Cookie file at #{path} is empty")
  defp ensure_non_empty!(contents, _path), do: contents
end
