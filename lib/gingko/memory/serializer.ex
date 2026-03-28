defmodule Gingko.Memory.Serializer do
  @moduledoc false

  alias Mnemosyne.NodeMetadata
  alias Mnemosyne.Pipeline.Reasoning.ReasonedMemory

  def project(%{project_id: project_id, repo_id: repo_id} = attrs) do
    %{
      project_id: project_id,
      repo_id: repo_id,
      custom_overlays?: Map.get(attrs, :custom_overlays?, false)
    }
  end

  def reasoned_memory(%ReasonedMemory{} = memory) do
    %{
      episodic: memory.episodic,
      semantic: memory.semantic,
      procedural: memory.procedural
    }
  end

  def node(nil), do: nil

  def node(%module{} = node) do
    node
    |> Map.from_struct()
    |> Map.delete(:__struct__)
    |> Map.update(:links, nil, &serialize_links/1)
    |> Map.put(:type, node_type(module))
  end

  def metadata(nil), do: nil

  def metadata(%NodeMetadata{} = meta) do
    meta
    |> Map.from_struct()
    |> Map.delete(:__struct__)
  end

  def metadata(value), do: value

  def without_embedding(nil), do: nil
  def without_embedding(node) when is_map(node), do: Map.delete(node, :embedding)

  defp serialize_links(links) when is_map(links) do
    Map.new(links, fn
      {type, %MapSet{} = ids} -> {type, MapSet.to_list(ids)}
      {type, ids} when is_list(ids) -> {type, ids}
    end)
  end

  defp serialize_links(value), do: value

  @doc """
  Extracts a human-readable label from a node map or struct.

  Works with both raw Mnemosyne node structs and serialized maps,
  falling back through content fields until one is found.
  """
  @spec node_label(map()) :: String.t()
  def node_label(%{label: label}) when is_binary(label), do: truncate_words(label)
  def node_label(%{proposition: p}) when is_binary(p), do: truncate_words(p)
  def node_label(%{description: d}) when is_binary(d), do: truncate_words(d)
  def node_label(%{instruction: i}) when is_binary(i), do: truncate_words(i)
  def node_label(%{observation: o}) when is_binary(o), do: truncate_words(o)
  def node_label(%{plain_text: t}) when is_binary(t), do: truncate_words(t)

  def node_label(%{episode_id: _episode_id, step_index: step_index}),
    do: "Source step #{step_index}"

  def node_label(%{id: id}), do: id

  @max_label_words 5
  defp truncate_words(text) do
    case String.split(text, ~r/\s+/, parts: @max_label_words + 1) do
      words when length(words) > @max_label_words ->
        words |> Enum.take(@max_label_words) |> Enum.join(" ") |> Kernel.<>("...")

      _ ->
        text
    end
  end

  defp node_type(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
