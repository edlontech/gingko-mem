defmodule Gingko.MCP.ToolResponse do
  @moduledoc false

  alias Anubis.Server.Response

  def from_result({:ok, result}, frame) do
    {:reply, Response.structured(Response.tool(), stringify(result)), frame}
  end

  def from_result({:error, error}, frame) do
    payload = %{"error" => stringify(error)}

    {:reply,
     Response.structured(Response.tool(), payload)
     |> Map.put(:isError, true), frame}
  end

  def from_text(text, frame) when is_binary(text) do
    {:reply, Response.text(Response.tool(), text), frame}
  end

  defp stringify(nil), do: nil
  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify(%Time{} = value), do: Time.to_iso8601(value)

  defp stringify(%_{} = value) do
    value
    |> Map.from_struct()
    |> Map.delete(:__struct__)
    |> stringify()
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value
end
