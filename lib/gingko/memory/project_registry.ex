defmodule Gingko.Memory.ProjectRegistry do
  @moduledoc false

  @in_memory Mnemosyne.GraphBackends.InMemory
  @dets Mnemosyne.GraphBackends.Persistence.DETS

  def resolve(project_id, opts \\ []) when is_binary(project_id) and project_id != "" do
    storage_root = Keyword.get(opts, :storage_root, storage_root())
    project_root = project_root(project_id, storage_root)

    %{
      project_id: project_id,
      repo_id: repo_id(project_id),
      project_root: project_root,
      root_memory_path: Path.join(project_root, "root.dets"),
      branches_root: Path.join(project_root, "branches"),
      backend: {@in_memory, persistence: {@dets, path: Path.join(project_root, "root.dets")}}
    }
  end

  def project_root(project_id, storage_root \\ storage_root()) do
    Path.join(storage_root, project_dirname(project_id))
  end

  def root_memory_path(project_id, storage_root \\ storage_root()) do
    project_id
    |> project_root(storage_root)
    |> Path.join("root.dets")
  end

  def branch_memory_path(project_id, branch_name, storage_root \\ storage_root()) do
    project_id
    |> project_root(storage_root)
    |> Path.join("branches")
    |> Path.join(branch_filename(branch_name))
  end

  def ensure_storage_root! do
    path = storage_root()
    File.mkdir_p!(path)
    path
  end

  def ensure_project_storage_root!(project_id, opts \\ []) do
    storage_root = Keyword.get(opts, :storage_root, storage_root())
    project = resolve(project_id, storage_root: storage_root)
    File.mkdir_p!(project.branches_root)
    project.project_root
  end

  def repo_id(project_id) when is_binary(project_id) do
    "project:" <> Base.url_encode64(project_id, padding: false)
  end

  def branch_repo_id(project_id, branch_name)
      when is_binary(project_id) and is_binary(branch_name) do
    repo_id(project_id) <> ":branch:" <> Base.url_encode64(branch_name, padding: false)
  end

  def decode_repo_id("project:" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, project_id} -> {:ok, project_id}
      :error -> :error
    end
  end

  def decode_repo_id(_), do: :error

  def storage_root do
    Application.fetch_env!(:gingko, Gingko.Memory)
    |> Keyword.fetch!(:storage_root)
  end

  defp project_dirname(project_id) do
    "#{slugify(project_id)}-#{short_digest(project_id)}"
  end

  defp branch_filename(branch_name) do
    slugify(branch_name) <> ".dets"
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      slug -> slug
    end
  end

  defp short_digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end
end
