defmodule GingkoWeb.ProjectLive.SearchControllerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Gingko.Memory
  alias GingkoWeb.ProjectLive.SearchController

  setup :set_mimic_global

  setup do
    Mimic.copy(Gingko.Memory)
    :ok
  end

  describe "submit/2" do
    test "flips status to :searching, sets search_text, and starts a supervised task" do
      stub(Memory, :recall, fn %{project_id: "p", query: "hello"} ->
        {:ok, %{touched_node_ids: []}}
      end)

      socket = fake_socket(%{project_id: "p", search_task_ref: nil})

      updated = SearchController.submit(socket, "hello")

      assert updated.assigns.search_text == "hello"
      assert updated.assigns.search_status == :searching
      assert is_reference(updated.assigns.search_task_ref)
    end

    test "demonitors a pre-existing task_ref before spawning the new one" do
      stub(Memory, :recall, fn _ -> {:ok, %{touched_node_ids: []}} end)

      fake_ref = make_ref()
      socket = fake_socket(%{project_id: "p", search_task_ref: fake_ref})

      # Should not raise despite the fake ref not being a real monitor.
      updated = SearchController.submit(socket, "q")
      assert updated.assigns.search_task_ref != fake_ref
      assert is_reference(updated.assigns.search_task_ref)
    end
  end

  describe "handle_result/3" do
    test "on {:ok, result}, sets :completed and stores result, clears task_ref" do
      socket = fake_socket(%{search_task_ref: make_ref()})
      result = {:ok, %{touched_node_ids: ["a"]}}

      updated = SearchController.handle_result(socket, make_ref(), result)

      assert updated.assigns.search_task_ref == nil
      assert updated.assigns.search_status == :completed
      assert updated.assigns.search_result == %{touched_node_ids: ["a"]}
    end

    test "on {:error, _}, sets :error and clears result" do
      socket = fake_socket(%{search_task_ref: make_ref(), search_result: :prior})
      result = {:error, :boom}

      updated = SearchController.handle_result(socket, make_ref(), result)

      assert updated.assigns.search_task_ref == nil
      assert updated.assigns.search_status == :error
      assert updated.assigns.search_result == nil
    end

    test "on unexpected reply, sets :error and clears result" do
      socket = fake_socket(%{search_task_ref: make_ref(), search_result: :prior})

      updated = SearchController.handle_result(socket, make_ref(), :weird_reply)

      assert updated.assigns.search_status == :error
      assert updated.assigns.search_result == nil
    end
  end

  describe "handle_down/1" do
    test "sets :error and clears task ref + result" do
      socket = fake_socket(%{search_task_ref: make_ref(), search_result: :prior})

      updated = SearchController.handle_down(socket)

      assert updated.assigns.search_task_ref == nil
      assert updated.assigns.search_status == :error
      assert updated.assigns.search_result == nil
    end
  end

  defp fake_socket(overrides) do
    assigns =
      Map.merge(
        %{
          project_id: "p",
          search_text: "",
          search_status: :idle,
          search_task_ref: nil,
          search_result: nil,
          __changed__: %{}
        },
        overrides
      )

    %Phoenix.LiveView.Socket{
      assigns: assigns,
      endpoint: GingkoWeb.Endpoint,
      transport_pid: nil
    }
  end
end
