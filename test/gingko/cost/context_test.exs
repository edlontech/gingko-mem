defmodule Gingko.Cost.ContextTest do
  use ExUnit.Case, async: true

  alias Gingko.Cost.Context

  test "current/0 is empty in a fresh process" do
    assert Context.current() == %{}
  end

  test "with/2 sets attrs for the duration of the block and clears on exit" do
    result =
      Context.with(%{project_key: "a", feature: :step_summarization}, fn ->
        Context.current()
      end)

    assert result == %{project_key: "a", feature: :step_summarization}
    assert Context.current() == %{}
  end

  test "nested with/2 merges and restores" do
    Context.with(%{project_key: "a"}, fn ->
      Context.with(%{feature: :project_summary}, fn ->
        assert Context.current() == %{project_key: "a", feature: :project_summary}
      end)

      assert Context.current() == %{project_key: "a"}
    end)

    assert Context.current() == %{}
  end

  test "inner with/2 overrides outer keys then restores" do
    Context.with(%{project_key: "a"}, fn ->
      Context.with(%{project_key: "b"}, fn ->
        assert Context.current().project_key == "b"
      end)

      assert Context.current().project_key == "a"
    end)
  end

  test "raise inside with/2 still restores" do
    assert_raise RuntimeError, "boom", fn ->
      Context.with(%{project_key: "a"}, fn -> raise "boom" end)
    end

    assert Context.current() == %{}
  end
end
