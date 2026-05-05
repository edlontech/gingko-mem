defmodule Gingko.Memory.Summarizer do
  @moduledoc """
  Extracts a single observation/action pair from raw assistant transcript
  content using the configured LLM provider.

  For inputs above the configured chunk size, runs a map-reduce pass: chunks
  are summarized in parallel, then a reduce call consolidates the partial
  pairs into a final pair.
  """

  require Logger

  alias Gingko.Summaries.Config
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

  @reduce_prompt """
  You are a memory consolidation system. You will be given several
  observation/action pairs extracted from contiguous slices of a single
  assistant transcript, in order. Merge them into one final observation and
  one final action pair that captures the whole transcript.

  - observation: 1-2 sentences covering what was discovered across all slices.
  - action: 1-2 sentences covering what was ultimately done and why.

  Be concise. Do not list slice numbers or meta-commentary.
  """

  @type pair :: %{observation: String.t(), action: String.t()}

  @spec extract(String.t()) :: {:ok, pair()} | {:error, term()}
  def extract(content) when is_binary(content) and byte_size(content) > 0 do
    case chunk(content, Config.chunk_chars()) do
      [single] -> extract_chunk(single)
      chunks -> map_reduce(chunks)
    end
  end

  def extract(_), do: {:error, :empty_content}

  @doc """
  Splits `content` into chunks no larger than `max_chars` bytes, breaking on
  line boundaries when possible. Lines that individually exceed `max_chars`
  are emitted as their own chunk (no mid-line splits).
  """
  @spec chunk(String.t(), pos_integer()) :: [String.t()]
  def chunk(content, max_chars)
      when is_binary(content) and is_integer(max_chars) and max_chars > 0 do
    if byte_size(content) <= max_chars do
      [content]
    else
      content
      |> String.split("\n")
      |> pack_lines(max_chars)
    end
  end

  defp pack_lines(lines, max_chars) do
    {chunks, current, _size} =
      Enum.reduce(lines, {[], [], 0}, fn line, {chunks, current, size} ->
        line_size = byte_size(line) + 1

        cond do
          current == [] ->
            {chunks, [line], line_size}

          size + line_size <= max_chars ->
            {chunks, [line | current], size + line_size}

          true ->
            {[finalize_chunk(current) | chunks], [line], line_size}
        end
      end)

    [finalize_chunk(current) | chunks] |> Enum.reverse()
  end

  defp finalize_chunk(lines), do: lines |> Enum.reverse() |> Enum.join("\n")

  defp map_reduce(chunks) do
    capped = Enum.take(chunks, Config.max_chunks())

    if length(chunks) > length(capped) do
      Logger.warning(
        "Summarizer: input split into #{length(chunks)} chunks, capped to #{length(capped)}"
      )
    end

    pairs = parallel_extract(capped)

    case pairs do
      [] -> {:error, :all_chunks_failed}
      [single] -> {:ok, single}
      many -> reduce_pairs(many)
    end
  end

  defp parallel_extract(chunks) do
    attribution = Gingko.Cost.Context.current()

    Gingko.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      chunks,
      fn chunk ->
        Gingko.Cost.Context.with(attribution, fn -> extract_chunk(chunk) end)
      end,
      max_concurrency: Config.parallelism(),
      timeout: Config.chunk_timeout_ms(),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.reduce({0, []}, fn
      {:ok, {:ok, pair}}, {idx, acc} ->
        {idx + 1, [pair | acc]}

      {:ok, {:error, reason}}, {idx, acc} ->
        Logger.warning("Summarizer: chunk #{idx} failed: #{inspect(reason)}")
        {idx + 1, acc}

      {:exit, reason}, {idx, acc} ->
        Logger.warning("Summarizer: chunk #{idx} exited: #{inspect(reason)}")
        {idx + 1, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp reduce_pairs(pairs) do
    payload = pairs |> Enum.with_index(1) |> Enum.map_join("\n\n", &format_pair/1)
    messages = [Message.system(@reduce_prompt), Message.user(payload)]

    case Sycophant.generate_object(llm_model(), messages, @schema) do
      {:ok, %{object: object}} ->
        {:ok, object}

      {:error, reason} ->
        Logger.warning("Summarizer: reduce step failed: #{inspect(reason)}; using first chunk")
        {:ok, hd(pairs)}
    end
  end

  defp format_pair({%{observation: obs, action: act}, idx}) do
    "Slice #{idx}:\nobservation: #{obs}\naction: #{act}"
  end

  defp extract_chunk(content) do
    messages = [Message.system(@prompt), Message.user(content)]

    case Sycophant.generate_object(llm_model(), messages, @schema) do
      {:ok, %{object: object}} -> {:ok, object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp llm_model do
    config = Application.fetch_env!(:gingko, Gingko.Memory)
    config |> Keyword.fetch!(:mnemosyne_config) |> Map.fetch!(:llm) |> Map.fetch!(:model)
  end
end
