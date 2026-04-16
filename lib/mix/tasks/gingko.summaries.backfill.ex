defmodule Mix.Tasks.Gingko.Summaries.Backfill do
  @shortdoc "Seed playbook rows and enqueue initial cluster regenerations for existing projects"

  @moduledoc """
  Seeds the per-project summaries state for every registered project.

  For each project returned by `Gingko.Projects.list_projects/0`:

    * upserts the static playbook section (`Gingko.Summaries.seed_playbook/1`)
    * ranks the top-K tags by `:membership` edge count via
      `Gingko.Memory.top_tags/2` (with `K = Gingko.Summaries.Config.hot_tags_k/0`)
    * upserts a dirty `cluster_summaries` row per tag so the primer has
      something to render before the worker finishes
    * enqueues `Gingko.Summaries.ClusterWorker` for each tag

  The task is idempotent: re-running it over a fully backfilled dataset does
  not create duplicate playbook rows or duplicate cluster rows. The worker
  enqueue honors `ClusterWorker`'s `unique: [...]` constraint, so pending jobs
  are deduped by `(project_key, tag_node_id)`.

  ## Usage

      mix gingko.summaries.backfill
  """

  use Mix.Task

  alias Gingko.Memory
  alias Gingko.Projects
  alias Gingko.Summaries
  alias Gingko.Summaries.ClusterWorker
  alias Gingko.Summaries.Config

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Projects.list_projects()
    |> Enum.each(&backfill_project/1)

    :ok
  end

  defp backfill_project(project) do
    project_key = project.project_key

    case Summaries.seed_playbook(project_key) do
      {:ok, _section} ->
        backfill_clusters(project_key)
        Mix.shell().info("summaries: backfilled #{project_key}")

      {:error, changeset} ->
        Mix.shell().error(
          "summaries: failed to seed playbook for #{project_key}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp backfill_clusters(project_key) do
    k = Config.hot_tags_k()

    case Memory.top_tags(project_key, k) do
      {:ok, tags} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        Enum.each(tags, &backfill_tag(project_key, &1, now))

      {:error, error} ->
        Mix.shell().info(
          "summaries: skipping cluster backfill for #{project_key} (#{inspect(error)})"
        )
    end
  end

  defp backfill_tag(project_key, tag, now) do
    Summaries.upsert_cluster(%{
      project_key: project_key,
      tag_node_id: tag.id,
      tag_label: tag.label,
      slug: slugify(tag.label, tag.id),
      memory_count: tag.memory_count,
      dirty: true,
      dirty_since: now
    })

    ClusterWorker.enqueue(%{project_key: project_key, tag_node_id: tag.id})
  end

  defp slugify(label, tag_id) when is_binary(label) do
    slug =
      label
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: tag_id, else: slug
  end

  defp slugify(_label, tag_id), do: tag_id
end
