defmodule Gingko.Cost.Pruner do
  @moduledoc """
  Daily Oban worker that deletes `Gingko.Cost.Call` rows older than
  `Cost.Config.retention_days()`. A retention of 0 disables pruning.
  """

  use Oban.Worker, queue: :maintenance

  import Ecto.Query

  alias Gingko.Cost.Call
  alias Gingko.Cost.Config
  alias Gingko.Repo

  @impl Oban.Worker
  def perform(_job) do
    case Config.retention_days() do
      days when is_integer(days) and days > 0 ->
        cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
        {count, _} = Repo.delete_all(from(c in Call, where: c.inserted_at < ^cutoff))
        {:ok, %{deleted: count, cutoff: cutoff}}

      _ ->
        {:ok, %{deleted: 0, skipped: :retention_disabled}}
    end
  end
end
