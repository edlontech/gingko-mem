defmodule Gingko.Memory.Summarizer do
  @moduledoc """
  Extracts structured observation/action pairs from raw assistant transcript
  content using the configured LLM provider.
  """

  alias Sycophant.Message

  @schema Zoi.map(
            %{
              observation: Zoi.string(),
              action: Zoi.string()
            },
            coerce: true
          )

  @prompt """
  You are a memory extraction system. Given an assistant's transcript content,
  extract a concise observation and action pair.

  - observation: What was discovered, analyzed, or encountered (1-2 sentences)
  - action: What was done in response and why (1-2 sentences)

  Be concise. Focus on the substance, not meta-commentary.
  """

  @spec extract(String.t()) ::
          {:ok, %{observation: String.t(), action: String.t()}} | {:error, term()}
  def extract(content) when is_binary(content) and byte_size(content) > 0 do
    model = llm_model()
    messages = [Message.system(@prompt), Message.user(content)]

    case Sycophant.generate_object(model, messages, @schema) do
      {:ok, %{object: object}} -> {:ok, object}
      {:error, reason} -> {:error, reason}
    end
  end

  def extract(_), do: {:error, :empty_content}

  defp llm_model do
    config = Application.fetch_env!(:gingko, Gingko.Memory)
    config |> Keyword.fetch!(:mnemosyne_config) |> Map.fetch!(:llm) |> Map.fetch!(:model)
  end
end
