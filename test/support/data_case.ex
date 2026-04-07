defmodule Gingko.DataCase do
  @moduledoc """
  Test case template for tests that touch `Gingko.Repo`.

  SQLite is configured with a single pool connection and no concurrent sandbox
  mode, so tests that use this case should run sequentially within their own
  module. Tables are truncated on setup so individual tests stay isolated.
  """

  use ExUnit.CaseTemplate

  alias Gingko.Repo

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Gingko.DataCase

      alias Gingko.Repo
    end
  end

  setup _tags do
    clean_summaries_tables()
    :ok
  end

  @doc """
  Clears the summaries tables so tests start from a known state.
  """
  def clean_summaries_tables do
    for table <- ~w(cluster_membership_deltas cluster_summaries principal_memory_sections) do
      Repo.query!("DELETE FROM #{table}")
    end

    :ok
  end

  @doc """
  Reduces a changeset's error list to a readable map.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
