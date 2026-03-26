defmodule GingkoWeb.EctoExceptions do
  @moduledoc """
  Host module for Plug.Exception implementations over Ecto errors.

  Stands in for `phoenix_ecto` (not a dependency). If `phoenix_ecto` is ever
  added, these impls will collide and should be removed.
  """
end

defimpl Plug.Exception, for: Ecto.NoResultsError do
  def status(_exception), do: 404
  def actions(_exception), do: []
end
