defmodule Gingko.Summaries do
  @moduledoc """
  Context for derived-memory artifacts (project charter and summary). Raw
  memories live in Mnemosyne; this context owns the SQLite-backed summary
  layer only.
  """

  import Ecto.Query

  alias Gingko.Repo
  alias Gingko.Summaries.Config
  alias Gingko.Summaries.PrimerRenderer
  alias Gingko.Summaries.PrincipalMemorySection

  @section_kinds PrincipalMemorySection.kinds()

  @doc """
  Renders the composed session-primer markdown for a project.

  Options:
    * `:recent_count` - number of raw memories to include in the recent tail
      (defaults to `Config.session_primer_recent_count/0`).
  """
  @spec render_primer(String.t(), keyword()) :: {:ok, String.t()}
  def render_primer(project_key, opts \\ []) when is_binary(project_key) do
    recent_count = Keyword.get(opts, :recent_count, Config.session_primer_recent_count())

    charter = section_content(project_key, "charter")
    summary = get_section(project_key, "summary")
    recent = fetch_recent_memories(project_key, recent_count)

    {:ok, PrimerRenderer.render(charter, summary, recent)}
  end

  defp section_content(project_key, kind) do
    case get_section(project_key, kind) do
      %PrincipalMemorySection{content: content} -> content
      nil -> nil
    end
  end

  defp fetch_recent_memories(project_key, recent_count) do
    case Gingko.Memory.latest_memories(%{project_id: project_key, top_k: recent_count}) do
      {:ok, %{memories: memories}} -> memories
      {:error, _} -> []
    end
  end

  @spec get_section(String.t(), String.t()) :: PrincipalMemorySection.t() | nil
  def get_section(project_key, kind) when kind in @section_kinds do
    Repo.get_by(PrincipalMemorySection, project_key: project_key, kind: kind)
  end

  @spec list_sections(String.t()) :: [PrincipalMemorySection.t()]
  def list_sections(project_key) do
    Repo.all(from(s in PrincipalMemorySection, where: s.project_key == ^project_key))
  end

  # Uses a find-or-new pattern instead of `Repo.insert(on_conflict: ...)`
  # because `ecto_sqlite3` with `:binary_id` primary keys returns the
  # client-generated UUID from the insert attempt rather than the stored row's
  # UUID on the UPDATE branch of `ON CONFLICT`, which breaks id stability.
  @spec upsert_section(map()) ::
          {:ok, PrincipalMemorySection.t()} | {:error, Ecto.Changeset.t()}
  def upsert_section(attrs) do
    project_key = Map.get(attrs, :project_key) || Map.get(attrs, "project_key")
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind")

    existing =
      if is_binary(project_key) and kind in @section_kinds do
        Repo.get_by(PrincipalMemorySection, project_key: project_key, kind: kind)
      end

    case existing do
      %PrincipalMemorySection{} = section ->
        section
        |> PrincipalMemorySection.changeset(attrs)
        |> Repo.update()

      nil ->
        %PrincipalMemorySection{}
        |> PrincipalMemorySection.changeset(attrs)
        |> Repo.insert()
    end
  end

  @doc """
  Upserts the charter section with respect to the `locked` flag.

  Returns `{:error, %{code: :invalid_params}}` when content is empty, and
  `{:error, %{code: :charter_locked}}` when the existing row is locked.
  Otherwise delegates to `upsert_section/1`.
  """
  @spec set_charter(String.t(), String.t()) ::
          {:ok, PrincipalMemorySection.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, %{code: atom(), message: String.t()}}
  def set_charter(_project_key, content) when content in [nil, ""] do
    {:error, %{code: :invalid_params, message: "`content` must be a non-empty string"}}
  end

  def set_charter(project_key, content) when is_binary(project_key) and is_binary(content) do
    case get_section(project_key, "charter") do
      %PrincipalMemorySection{locked: true} ->
        {:error,
         %{
           code: :charter_locked,
           message: "charter is locked and cannot be overwritten"
         }}

      _ ->
        upsert_section(%{project_key: project_key, kind: "charter", content: content})
    end
  end
end
