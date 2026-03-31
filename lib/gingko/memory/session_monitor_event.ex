defmodule Gingko.Memory.SessionMonitorEvent do
  @moduledoc false

  @enforce_keys [:type, :project_id, :repo_id, :timestamp]
  defstruct [
    :type,
    :project_id,
    :repo_id,
    :timestamp,
    :session_id,
    node_ids: [],
    summary: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Derives a stable, unique key for an event by hashing its fields.
  """
  @spec event_key(t()) :: String.t()
  def event_key(%__MODULE__{} = event) do
    event
    |> Map.take([
      :type,
      :project_id,
      :repo_id,
      :session_id,
      :timestamp,
      :node_ids,
      :summary
    ])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
