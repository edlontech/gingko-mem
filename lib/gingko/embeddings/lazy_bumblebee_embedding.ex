defmodule Gingko.Embeddings.LazyBumblebeeEmbedding do
  @moduledoc false

  @behaviour Mnemosyne.Embedding

  alias Gingko.Embeddings.BumblebeeServing
  alias Mnemosyne.Adapters.BumblebeeEmbedding
  alias Mnemosyne.Errors.Framework.AdapterError

  @impl true
  def embed(text, opts) do
    with {:ok, serving} <- ensure_serving(:embed, opts) do
      BumblebeeEmbedding.embed(text, Keyword.put(opts, :serving, serving))
    end
  end

  @impl true
  def embed_batch(texts, opts) do
    with {:ok, serving} <- ensure_serving(:embed_batch, opts) do
      BumblebeeEmbedding.embed_batch(texts, Keyword.put(opts, :serving, serving))
    end
  end

  defp ensure_serving(operation, opts) do
    model_name = Keyword.get(opts, :model)

    case BumblebeeServing.ensure_started(model_name) do
      {:ok, serving} ->
        {:ok, serving}

      {:error, reason} ->
        {:error,
         AdapterError.exception(adapter: :bumblebee, operation: operation, reason: reason)}
    end
  end
end
