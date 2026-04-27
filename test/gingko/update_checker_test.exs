defmodule Gingko.UpdateCheckerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Gingko.UpdateChecker

  setup :set_mimic_global

  setup do
    Mimic.copy(Req)
    Phoenix.PubSub.subscribe(Gingko.PubSub, UpdateChecker.topic())
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Gingko.PubSub, UpdateChecker.topic()) end)
    :ok
  end

  defp release_response(tag) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{"tag_name" => tag, "html_url" => "https://example.test/release/#{tag}"}
     }}
  end

  defp start_checker!(opts) do
    base = [
      name: :"checker_#{System.unique_integer([:positive])}",
      interval: :timer.minutes(60),
      retry_interval: :timer.minutes(5)
    ]

    start_supervised!({UpdateChecker, Keyword.merge(base, opts)})
  end

  describe "first check" do
    test "marks status :up_to_date when latest matches current" do
      stub(Req, :get, fn _ -> release_response("v0.1.0") end)
      start_checker!(current_version: "0.1.0")

      assert_receive {:update_status, :up_to_date}, 500
      assert UpdateChecker.status() == :up_to_date
    end

    test "marks status :update_available when latest is newer" do
      stub(Req, :get, fn _ -> release_response("v0.2.0") end)
      start_checker!(current_version: "0.1.0")

      assert_receive {:update_status, {:update_available, info}}, 500
      assert info.current == "0.1.0"
      assert info.latest == "0.2.0"
      assert info.html_url == "https://example.test/release/v0.2.0"
      assert {:update_available, _} = UpdateChecker.status()
    end

    test "treats 404 as :up_to_date so a brand new repo does not flap" do
      stub(Req, :get, fn _ -> {:ok, %Req.Response{status: 404, body: %{}}} end)
      start_checker!(current_version: "0.1.0")

      assert_receive {:update_status, :up_to_date}, 500
    end

    test "stays :unknown on transport errors" do
      stub(Req, :get, fn _ -> {:error, %RuntimeError{message: "boom"}} end)
      pid = start_checker!(current_version: "0.1.0")

      _ = :sys.get_state(pid)
      assert UpdateChecker.status() == :unknown
    end

    test "stays :unknown when current version cannot be parsed" do
      stub(Req, :get, fn _ -> release_response("v9.9.9") end)
      pid = start_checker!(current_version: "not-a-version")

      _ = :sys.get_state(pid)
      assert UpdateChecker.status() == :unknown
    end

    test "handles release tags prefixed like `gingko-v0.2.0`" do
      stub(Req, :get, fn _ -> release_response("gingko-v0.2.0") end)
      start_checker!(current_version: "0.1.0")

      assert_receive {:update_status, {:update_available, info}}, 500
      assert info.latest == "0.2.0"
    end
  end

  describe "parse_tag/1" do
    test "extracts the SemVer portion regardless of prefix" do
      assert UpdateChecker.parse_tag("v1.2.3") == "1.2.3"
      assert UpdateChecker.parse_tag("gingko-v0.1.0") == "0.1.0"
      assert UpdateChecker.parse_tag("release-2.0.0-rc.1") == "2.0.0-rc.1"
      assert UpdateChecker.parse_tag("0.5.0+build.7") == "0.5.0+build.7"
      assert UpdateChecker.parse_tag("not-a-version") == "not-a-version"
    end
  end

  describe "check_now/1" do
    test "re-runs the fetch on demand and broadcasts only on change" do
      counter = :counters.new(1, [:atomics])

      stub(Req, :get, fn _ ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> release_response("v0.1.0")
          _ -> release_response("v0.2.0")
        end
      end)

      pid = start_checker!(current_version: "0.1.0")
      assert_receive {:update_status, :up_to_date}, 500

      UpdateChecker.check_now(pid)
      assert_receive {:update_status, {:update_available, %{latest: "0.2.0"}}}, 500
    end
  end
end
