defmodule Gingko.Providers.GithubCopilotAuthTest do
  use ExUnit.Case, async: false

  alias Gingko.Providers.GithubCopilotAuth

  defmodule StubHttp do
    @moduledoc false

    def post(_url, _opts) do
      case Process.get(:copilot_post_responses, []) do
        [response | rest] ->
          Process.put(:copilot_post_responses, rest)
          Process.put(:copilot_post_calls, (Process.get(:copilot_post_calls) || 0) + 1)
          response

        [] ->
          raise "StubHttp.post called with no queued response"
      end
    end

    def get(_url, _opts) do
      case Process.get(:copilot_get_responses, []) do
        [response | rest] ->
          Process.put(:copilot_get_responses, rest)
          response

        [] ->
          raise "StubHttp.get called with no queued response"
      end
    end
  end

  setup do
    previous = Application.get_env(:gingko, GithubCopilotAuth)

    Application.put_env(:gingko, GithubCopilotAuth,
      http: StubHttp,
      sleeper: fn _ -> :ok end
    )

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:gingko, GithubCopilotAuth)
      else
        Application.put_env(:gingko, GithubCopilotAuth, previous)
      end
    end)

    :ok
  end

  defp queue_post(responses), do: Process.put(:copilot_post_responses, responses)
  defp queue_get(responses), do: Process.put(:copilot_get_responses, responses)

  describe "start_device_flow/0" do
    test "returns parsed device data on 200" do
      queue_post([
        {:ok,
         %{
           status: 200,
           body: %{
             "device_code" => "dc",
             "user_code" => "ABCD-EFGH",
             "verification_uri" => "https://github.com/login/device",
             "interval" => 5,
             "expires_in" => 900
           }
         }}
      ])

      assert {:ok, device} = GithubCopilotAuth.start_device_flow()
      assert device.device_code == "dc"
      assert device.user_code == "ABCD-EFGH"
      assert device.verification_uri == "https://github.com/login/device"
      assert device.interval == 5
    end

    test "surfaces non-200 status as an error" do
      queue_post([{:ok, %{status: 503, body: %{"error" => "down"}}}])

      assert {:error, {:unexpected_status, 503, _}} = GithubCopilotAuth.start_device_flow()
    end
  end

  describe "poll_for_token/3" do
    test "returns the access_token when GitHub approves" do
      queue_post([{:ok, %{status: 200, body: %{"access_token" => "gho_tok"}}}])

      assert {:ok, "gho_tok"} = GithubCopilotAuth.poll_for_token("dc", 1)
    end

    test "retries on authorization_pending then succeeds" do
      queue_post([
        {:ok, %{status: 200, body: %{"error" => "authorization_pending"}}},
        {:ok, %{status: 200, body: %{"error" => "authorization_pending"}}},
        {:ok, %{status: 200, body: %{"access_token" => "gho_tok"}}}
      ])

      assert {:ok, "gho_tok"} = GithubCopilotAuth.poll_for_token("dc", 1)
      assert Process.get(:copilot_post_calls) == 3
    end

    test "halts on a fatal GitHub error" do
      queue_post([{:ok, %{status: 200, body: %{"error" => "expired_token"}}}])

      assert {:error, {:github, "expired_token"}} = GithubCopilotAuth.poll_for_token("dc", 1)
    end

    test "respects max_polls" do
      queue_post(
        for _ <- 1..5,
            do: {:ok, %{status: 200, body: %{"error" => "authorization_pending"}}}
      )

      assert {:error, :timeout} = GithubCopilotAuth.poll_for_token("dc", 1, max_polls: 2)
    end
  end

  describe "verify_token/1" do
    test "returns metadata on 200" do
      queue_get([{:ok, %{status: 200, body: %{"token" => "x"}}}])

      assert {:ok, %{"token" => "x"}} = GithubCopilotAuth.verify_token("gho_tok")
    end

    test "surfaces non-200 as error" do
      queue_get([{:ok, %{status: 401, body: %{"error" => "bad"}}}])

      assert {:error, {:unexpected_status, 401, _}} = GithubCopilotAuth.verify_token("gho_tok")
    end
  end
end
