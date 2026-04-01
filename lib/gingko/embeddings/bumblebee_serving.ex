defmodule Gingko.Embeddings.BumblebeeServing do
  @moduledoc """
  Lazily starts the shared Nx.Serving used for Bumblebee-backed embeddings.
  """

  use GenServer

  alias Gingko.Settings

  @name __MODULE__
  @manager_name Module.concat(__MODULE__, Manager)

  @type state :: %{
          model_name: String.t(),
          serving_builder: (String.t() -> {:ok, Nx.Serving.t()} | {:error, term()}),
          serving_starter: (Nx.Serving.t(), keyword() -> {:ok, pid()} | {:error, term()})
        }

  @spec name() :: module()
  def name, do: @name

  @spec manager_name() :: module()
  def manager_name, do: @manager_name

  @spec child_spec(Settings.t(), keyword()) :: Supervisor.child_spec() | nil
  def child_spec(settings, opts \\ [])

  def child_spec(%Settings{embeddings: %{provider: "bumblebee", model: model}}, opts) do
    start_opts = Keyword.put_new(opts, :model_name, model)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [start_opts]},
      type: :worker
    }
  end

  def child_spec(%Settings{}, _opts), do: nil

  def child_spec(opts, []) when is_list(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: manager_name())
  end

  @spec ensure_started(String.t()) :: {:ok, module()} | {:error, term()}
  def ensure_started(model_name) when is_binary(model_name) and model_name != "" do
    GenServer.call(manager_name(), {:ensure_started, model_name}, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       model_name: Keyword.fetch!(opts, :model_name),
       serving_builder: Keyword.get(opts, :serving_builder, &build_serving/1),
       serving_starter: Keyword.get(opts, :serving_starter, &start_serving/2)
     }}
  end

  @impl true
  def handle_call({:ensure_started, model_name}, _from, state) do
    reply =
      cond do
        state.model_name != model_name ->
          {:error, {:model_mismatch, configured: state.model_name, requested: model_name}}

        Process.whereis(name()) ->
          {:ok, name()}

        true ->
          start_serving_once(state)
      end

    {:reply, reply, state}
  end

  @compile_opts [batch_size: 4, sequence_length: 512]

  @spec build_serving(String.t(), keyword()) :: {:ok, Nx.Serving.t()} | {:error, term()}
  def build_serving(model_name, opts \\ []) when is_binary(model_name) and model_name != "" do
    repo = {:hf, model_name}
    model_loader = Keyword.get(opts, :model_loader, &Bumblebee.load_model/1)
    tokenizer_loader = Keyword.get(opts, :tokenizer_loader, &Bumblebee.load_tokenizer/1)

    text_embedding_builder =
      Keyword.get(opts, :text_embedding_builder, &Bumblebee.Text.text_embedding/3)

    defn_compiler = Keyword.get(opts, :defn_compiler, &defn_compiler/0)

    with {:ok, model_info} <- model_loader.(repo),
         {:ok, tokenizer} <- tokenizer_loader.(repo) do
      {:ok,
       text_embedding_builder.(model_info, tokenizer,
         compile: @compile_opts,
         defn_options: [compiler: defn_compiler.()]
       )}
    end
  end

  defp start_serving_once(state) do
    with {:ok, serving} <- state.serving_builder.(state.model_name),
         {:ok, _pid} <- state.serving_starter.(serving, name: name()) do
      {:ok, name()}
    else
      {:error, {:already_started, _pid}} -> {:ok, name()}
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  defp start_serving(serving, opts) do
    Nx.Serving.start_link(Keyword.merge([serving: serving], opts))
  end

  defp defn_compiler do
    case :os.type() do
      {:unix, :darwin} -> EMLX
      _ -> EXLA
    end
  end
end
