defmodule Gingko.Memory.ProjectRegistryTest do
  use ExUnit.Case, async: false

  test "resolve returns deterministic project paths" do
    left = Gingko.Memory.ProjectRegistry.resolve("/tmp/my-project")
    right = Gingko.Memory.ProjectRegistry.resolve("/tmp/my-project")

    assert left.project_root == right.project_root
    assert left.root_memory_path == right.root_memory_path
    assert left.branches_root == right.branches_root
    assert String.ends_with?(left.root_memory_path, "/root.dets")
  end

  @tag :tmp_dir
  test "resolve uses the configured storage root", %{tmp_dir: tmp_dir} do
    memory_config = Application.fetch_env!(:gingko, Gingko.Memory)

    on_exit(fn ->
      Application.put_env(:gingko, Gingko.Memory, memory_config)
    end)

    Application.put_env(
      :gingko,
      Gingko.Memory,
      Keyword.put(memory_config, :storage_root, tmp_dir)
    )

    project = Gingko.Memory.ProjectRegistry.resolve("configured-root")

    assert Path.dirname(project.project_root) == tmp_dir
    assert String.starts_with?(project.root_memory_path, project.project_root)
    assert String.ends_with?(project.root_memory_path, "/root.dets")
    assert String.starts_with?(project.branches_root, project.project_root)
  end

  @tag :tmp_dir
  test "branch_memory_path nests branch files under branches with safe names", %{tmp_dir: tmp_dir} do
    memory_config = Application.fetch_env!(:gingko, Gingko.Memory)

    on_exit(fn ->
      Application.put_env(:gingko, Gingko.Memory, memory_config)
    end)

    Application.put_env(
      :gingko,
      Gingko.Memory,
      Keyword.put(memory_config, :storage_root, tmp_dir)
    )

    path =
      Gingko.Memory.ProjectRegistry.branch_memory_path("configured-root", "feature/test branch")

    assert String.starts_with?(path, Path.join(tmp_dir, "configured-root-"))
    assert String.ends_with?(path, "/branches/feature-test-branch.dets")
  end

  describe "decode_repo_id/1" do
    test "round trips a Gingko repo id" do
      repo_id = Gingko.Memory.ProjectRegistry.repo_id("round-trip")
      assert {:ok, "round-trip"} = Gingko.Memory.ProjectRegistry.decode_repo_id(repo_id)
    end

    test "returns :error for unknown repo prefixes" do
      assert :error = Gingko.Memory.ProjectRegistry.decode_repo_id("other:abc")
    end

    test "returns :error for malformed base64" do
      assert :error = Gingko.Memory.ProjectRegistry.decode_repo_id("project:!!notbase64!!")
    end
  end
end
