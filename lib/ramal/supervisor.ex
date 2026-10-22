defmodule Ramal.Supervisor do
  @moduledoc """
  The supervision tree of Ramal. Add it to the host application's tree:

      children = [
        MyApp.Repo,
        {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}
      ]

  It starts a `Registry` keyed by branch id, a `DynamicSupervisor` for the branch processes, and owns the ETS
  tables the library needs. There is one instance per node; its configuration lives in `:persistent_term`.

  ## Options

    * `:storage` - a `Ramal.Storage` module, default `Ramal.Storage.ETS`
    * `:idle_timeout` - milliseconds without a call before a branch persists and unloads, default five minutes
    * `:max_heap_size` - the heap limit of each branch process in words, default 25 million (200 MB on a 64-bit
      machine). A branch exceeding it is killed and its last persisted state remains.
    * any other option is the storage config, for example `:repo` for the Postgres backend

  `idle_timeout` and `max_heap_size` belong to the supervisor, not to a branch, because a per-branch value would be
  forgotten when the branch is unloaded and loaded again.

  ## Example

      iex> opts = [storage: Ramal.Storage.ETS, idle_timeout: 1_000, repo: MyApp.Repo]
      iex> config = Ramal.Supervisor.build_config(opts)
      iex> {config.storage, config.idle_timeout, config.storage_config}
      {Ramal.Storage.ETS, 1000, [repo: MyApp.Repo]}
  """

  use Supervisor

  alias Ramal.Error

  @registry Ramal.Registry
  @dynamic Ramal.BranchSupervisor
  @config_key {__MODULE__, :config}
  @default_idle_timeout :timer.minutes(5)
  @default_max_heap_size 25_000_000

  @type config :: %{
          storage: module,
          storage_config: keyword,
          idle_timeout: timeout,
          max_heap_size: pos_integer
        }

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # init/1 runs in the supervisor process, so the tables are owned by it and live exactly as long as it does.
    create_table(Ramal.Storage.ETS)
    create_table(__MODULE__)
    :persistent_term.put(@config_key, build_config(opts))

    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp create_table(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    end
  end

  @doc """
  Builds the runtime config from the supervisor options.

  ## Example

      iex> Ramal.Supervisor.build_config([]).idle_timeout
      300000
  """
  @spec build_config(keyword) :: config
  def build_config(opts) do
    {known, storage_config} = Keyword.split(opts, [:storage, :idle_timeout, :max_heap_size])

    %{
      storage: Keyword.get(known, :storage, Ramal.Storage.ETS),
      storage_config: storage_config,
      idle_timeout: Keyword.get(known, :idle_timeout, @default_idle_timeout),
      max_heap_size: Keyword.get(known, :max_heap_size, @default_max_heap_size)
    }
  end

  @doc false
  @spec config() :: {:ok, config} | {:error, Error.t()}
  def config do
    # persistent_term outlives the supervisor, so also require the supervisor to be alive.
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         config when not is_nil(config) <- :persistent_term.get(@config_key, nil) do
      {:ok, config}
    else
      _ ->
        {:error,
         Error.new(
           :not_started,
           "Ramal.Supervisor is not running; add {Ramal.Supervisor, opts} to your supervision tree"
         )}
    end
  end

  @doc false
  def registry, do: @registry

  @doc false
  def dynamic_supervisor, do: @dynamic

  @doc false
  def via(id), do: {:via, Registry, {@registry, id}}

  @doc false
  @spec whereis(String.t()) :: pid | nil
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      # The Registry drops the entry of a dead process a moment late, so check that the pid is still alive.
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc false
  def mark_too_large(id), do: :ets.insert(__MODULE__, {{:too_large, id}, true})

  @doc false
  def too_large?(id), do: :ets.member(__MODULE__, {:too_large, id})

  @doc false
  def clear_too_large(id), do: :ets.delete(__MODULE__, {:too_large, id})
end
