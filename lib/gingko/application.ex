defmodule Gingko.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Gingko.Embeddings.BumblebeeServing
  alias Gingko.Settings
  alias Mnemosyne.Supervisor, as: MnemosyneSupervisor

  @impl true
  def start(_type, _args) do
    Gingko.NxBackend.configure()
    setup_file_logger()
    migrate_metadata!()

    children =
      [
        Gingko.Repo,
        {Oban, Application.fetch_env!(:gingko, Oban)},
        GingkoWeb.Telemetry,
        {Phoenix.PubSub, name: Gingko.PubSub},
        Gingko.Memory.ActivityStore,
        Gingko.Memory.GraphCluster,
        Gingko.Memory.ProjectStatsBroadcaster
      ] ++
        embedding_children() ++
        [
          {MnemosyneSupervisor, Gingko.Memory.mnemosyne_supervisor_opts()},
          Gingko.Memory.OverlayReloader,
          Anubis.Server.Registry,
          {Gingko.MCP.Server, transport: {:streamable_http, start: true}},
          {Task.Supervisor, name: Gingko.TaskSupervisor},
          Gingko.Memory.SessionSweeper,
          GingkoWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Gingko.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      Gingko.Projects.abandon_active_sessions()
      :ok = Gingko.Memory.reopen_registered_projects()
      _ = Gingko.Summaries.DirtyTracker.attach()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GingkoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @doc """
  Applies new runtime settings and refreshes long-lived children that cache them.
  """
  @spec sync_runtime_settings(Settings.t(), keyword()) :: :ok
  def sync_runtime_settings(%Settings{} = settings, _opts \\ []) do
    memory_runtime = Settings.mnemosyne_runtime(settings)
    memory_config = Application.get_env(:gingko, Gingko.Memory, [])

    Application.put_env(:gingko, :settings, settings)

    Application.put_env(
      :gingko,
      Gingko.Memory,
      Keyword.merge(
        memory_config,
        storage_root: memory_runtime.storage_root,
        mnemosyne_config: memory_runtime.mnemosyne_config,
        llm_adapter: memory_runtime.llm_adapter,
        embedding_adapter: memory_runtime.embedding_adapter
      )
    )

    Application.put_env(:gingko, Gingko.Summaries.Config, Settings.summaries_env(settings))

    refresh_runtime_children()
  end

  @doc """
  Restarts runtime children that snapshot configuration at boot.
  """
  @spec refresh_runtime_children() :: :ok
  def refresh_runtime_children do
    :ok = restart_mnemosyne_supervisor()
    :ok = sync_bumblebee_serving_child()
    :ok = Gingko.Memory.reopen_registered_projects()
  end

  defp embedding_children do
    case Application.get_env(:gingko, :settings) do
      %Gingko.Settings{} = settings ->
        case Gingko.Embeddings.BumblebeeServing.child_spec(settings) do
          nil -> []
          child -> [child]
        end

      _ ->
        []
    end
  end

  defp migrate_metadata! do
    path = Application.app_dir(:gingko, "priv/repo/migrations")

    Ecto.Migrator.with_repo(Gingko.Repo, fn repo ->
      Ecto.Migrator.run(repo, path, :up, all: true)
    end)

    :ok
  end

  defp restart_mnemosyne_supervisor do
    supervisor = Gingko.Supervisor
    child_id = MnemosyneSupervisor

    if child_running?(supervisor, child_id) do
      :ok = Supervisor.terminate_child(supervisor, child_id)
      :ok = Supervisor.delete_child(supervisor, child_id)
    end

    case Supervisor.start_child(
           supervisor,
           {MnemosyneSupervisor, Gingko.Memory.mnemosyne_supervisor_opts()}
         ) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp sync_bumblebee_serving_child do
    supervisor = Gingko.Supervisor
    child_id = BumblebeeServing
    desired_child = desired_bumblebee_child()

    if child_running?(supervisor, child_id) do
      :ok = Supervisor.terminate_child(supervisor, child_id)
      :ok = Supervisor.delete_child(supervisor, child_id)
    end

    case desired_child do
      nil ->
        :ok

      child_spec ->
        case Supervisor.start_child(supervisor, child_spec) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
    end
  end

  defp desired_bumblebee_child do
    case Application.get_env(:gingko, :settings) do
      %Settings{} = settings -> BumblebeeServing.child_spec(settings)
      _ -> nil
    end
  end

  defp setup_file_logger do
    case Application.get_env(:gingko, :log_file) do
      nil ->
        :ok

      path ->
        :logger.add_handler(:file_handler, :logger_std_h, %{
          config: %{
            file: String.to_charlist(path),
            max_no_bytes: 5_000_000,
            max_no_files: 5,
            compress_on_rotate: true
          },
          formatter:
            Logger.Formatter.new(
              format: "$time $metadata[$level] $message\n",
              metadata: [:request_id]
            )
        })
    end
  end

  defp child_running?(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.any?(fn {id, _pid, _type, _modules} -> id == child_id end)
  end
end
