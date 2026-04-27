defmodule Gingko.CLI.ProjectIdTest do
  use ExUnit.Case, async: true

  alias Gingko.CLI.ProjectId

  describe "from_remote/1" do
    @cases [
      {"git@github.com:edlontech/gingko.git", "edlontech--gingko"},
      {"git@github.com:edlontech/gingko", "edlontech--gingko"},
      {"https://github.com/edlontech/gingko.git", "edlontech--gingko"},
      {"https://github.com/edlontech/gingko", "edlontech--gingko"},
      {"ssh://git@github.com/edlontech/gingko.git", "edlontech--gingko"},
      {"git://github.com/edlontech/gingko.git", "edlontech--gingko"},
      {"https://gitlab.example.com/team/sub/repo.git", "sub--repo"},
      {"  https://github.com/edlontech/gingko.git\n", "edlontech--gingko"}
    ]

    for {url, expected} <- @cases do
      test "parses #{inspect(url)} as #{expected}" do
        assert ProjectId.from_remote(unquote(url)) == unquote(expected)
      end
    end

    test "returns nil for an unparseable single-segment URL" do
      assert ProjectId.from_remote("scheme-only") == nil
    end
  end

  describe "detect/1" do
    @tag :tmp_dir
    test "falls back to the basename of the working directory when there is no git origin",
         %{tmp_dir: tmp_dir} do
      sub = Path.join(tmp_dir, "weird-name")
      File.mkdir!(sub)
      run!("git", ["init", "--quiet"], sub)

      assert ProjectId.detect(sub) == "weird-name"
    end

    @tag :tmp_dir
    test "uses git origin when one is configured", %{tmp_dir: tmp_dir} do
      run!("git", ["init", "--quiet"], tmp_dir)
      run!("git", ["remote", "add", "origin", "git@github.com:edlontech/gingko.git"], tmp_dir)

      assert ProjectId.detect(tmp_dir) == "edlontech--gingko"
    end
  end

  defp run!(cmd, args, cwd) do
    {_, 0} = System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true)
  end
end
