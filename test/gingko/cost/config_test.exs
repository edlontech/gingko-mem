defmodule Gingko.Cost.ConfigTest do
  use ExUnit.Case, async: false

  alias Gingko.Cost.Config

  test "returns defaults when no env override is present" do
    assert is_boolean(Config.enabled?())
    assert is_integer(Config.retention_days())
    assert Config.batch_size_max() > 0
    assert Config.flush_interval_ms() > 0
  end
end
