defmodule Gingko.CredentialsTest do
  use Gingko.DataCase, async: false
  use Mimic

  alias Gingko.Credentials
  alias Gingko.Credentials.Runtime

  setup :verify_on_exit!

  setup do
    Mimic.copy(Runtime)

    stub(Runtime, :put_provider, fn _, _ -> :ok end)
    stub(Runtime, :delete_provider, fn _ -> :ok end)
    :ok
  end

  describe "put/4" do
    test "inserts a credential and pushes it into Sycophant runtime" do
      expect(Runtime, :put_provider, fn :github_copilot, [github_token: "gho_abc"] -> :ok end)

      assert {:ok, credential} = Credentials.put(:github_copilot, :github_token, "gho_abc")
      assert credential.provider == "github_copilot"
      assert credential.key == "github_token"
      assert credential.value == "gho_abc"
    end

    test "updates an existing credential" do
      expect(Runtime, :put_provider, 2, fn :github_copilot, _ -> :ok end)

      assert {:ok, _} = Credentials.put(:github_copilot, :github_token, "gho_old")
      assert {:ok, _} = Credentials.put(:github_copilot, :github_token, "gho_new")

      assert Credentials.get(:github_copilot, :github_token) == "gho_new"
    end
  end

  describe "list/1" do
    test "returns all credentials for a provider as keyword list" do
      stub(Runtime, :put_provider, fn _, _ -> :ok end)

      {:ok, _} = Credentials.put(:github_copilot, :github_token, "gho_abc")
      {:ok, _} = Credentials.put(:github_copilot, :github_host, "github.com")

      list = Credentials.list(:github_copilot)
      assert Keyword.get(list, :github_token) == "gho_abc"
      assert Keyword.get(list, :github_host) == "github.com"
    end
  end

  describe "delete_all/1" do
    test "wipes credentials and clears Sycophant runtime entry" do
      stub(Runtime, :put_provider, fn _, _ -> :ok end)
      expect(Runtime, :delete_provider, fn :github_copilot -> :ok end)

      {:ok, _} = Credentials.put(:github_copilot, :github_token, "gho_abc")
      assert :ok = Credentials.delete_all(:github_copilot)
      assert Credentials.get(:github_copilot, :github_token) == nil
    end
  end

  describe "sync_runtime/0" do
    test "replays every stored credential into Sycophant" do
      stub(Runtime, :put_provider, fn _, _ -> :ok end)

      {:ok, _} = Credentials.put(:github_copilot, :github_token, "gho_abc")
      {:ok, _} = Credentials.put(:openai, :api_key, "sk-test")

      expect(Runtime, :put_provider, fn :github_copilot, [github_token: "gho_abc"] -> :ok end)
      expect(Runtime, :put_provider, fn :openai, [api_key: "sk-test"] -> :ok end)

      assert :ok = Credentials.sync_runtime()
    end
  end
end
