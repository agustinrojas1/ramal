defmodule Ramal.Supervisor do
  @moduledoc """
  The supervision tree of Ramal. Add it to the host application's tree:

      children = [
        MyApp.Repo,
        {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}
      ]

  It starts a `Registry` keyed by branch id, a `DynamicSupervisor` for the branch processes, and owns the ETS
  tables the library needs. There is one instance per node; its configuration lives in `:persistent_term`.

  At start it logs a warning for each of Ash and AshPostgres that is outside the versions `Ramal.Ash` is tested with.
  Outside them it also runs Ramal's Ash contract (`mix ramal.doctor` runs the same checks), logs one more warning with its
  result, naming the assumptions that are broken, and emits `[:ramal, :ash, :contract]`; a branch then refuses the work that relies on a broken one with
  `:ash_incompatible` (ADR 0049). It never refuses to start.

  A branch lives on one node. To let every node of a cluster use the same branches, see `:cluster` below.

  ## Options

    * `:storage` - a `Ramal.Storage` module, default `Ramal.Storage.ETS`
    * `:idle_timeout` - milliseconds without a call before a branch persists and unloads, default five minutes
    * `:max_active_branches` - the most open and proposed branches one domain may have, default `nil` (no limit).
      `Ramal.branch/2` and `Ramal.fork/2` return `{:error, %Ramal.Error{reason: :limit_reached}}` at the limit. A soft
      limit: callers that create at the same moment can pass it by their own number. Counting asks the storage
      for a count (`c:Ramal.Storage.count/3`), so it costs one query with `Ramal.Storage.Postgres`.
    * `:branch_rate` - `{count, milliseconds}`: the most branches (created or forked) one domain may get in a window,
      default `nil`. Fixed windows, counted in memory on this node, and shared by `branch/2` and `fork/2`. Nodes do not
      add up: a cluster allows the rate on each node.
    * `:cluster` - `true` to run branches in a cluster, default `false` (ADR 0044). Branch processes are then named with
      `:global`, so one process serves a branch for every node, and the storage fences a process that lost the branch
      (see "Running in a cluster" below). The storage must define `c:Ramal.Storage.claim/2`: `Ramal.Storage.Postgres`
      does, with the `epoch` column `mix ramal.gen.migration` adds.
    * `:max_heap_size` - the heap limit of each branch process in words, default 25 million (200 MB on a 64-bit
      machine). A branch exceeding it is killed and its last persisted state remains.
    * `:durable` - `true` to make every branch durable unless `Ramal.branch/2` says otherwise, default `false`
      (ADR 0048). A durable branch appends the writes of each action that ends to the storage's write log before the
      action returns, so a crash of the node loses none of them. The fingerprints of rows the branch read and did not
      write since its last save are not in that log, so after a crash the merge cannot tell that such a row changed in
      the database; every row an action wrote keeps its fingerprint. The storage must define `c:Ramal.Storage.append/4`
      and `c:Ramal.Storage.writes_after/2`, as `Ramal.Storage.ETS` and `Ramal.Storage.Postgres` do; the supervisor
      refuses to start otherwise. It costs one storage write per action.
    * any other option is the storage config, for example `:repo` for the Postgres backend

  Both limits are off by default, so adding them is the only change; see ADR 0016 for why they exist (a client that can
  reach `Ramal.fork/2`, such as the inspector, can otherwise start a process and a stored row per call).

  ## Running in a cluster

  With `cluster: true` the supervisor on each node starts the processes that load a branch on that node, and `:global`
  makes sure only one runs. Every node needs the same code, because a node sends closures to the node that holds the
  branch (the write and capture calls of the branch process), which a release does anyway. Every node must use the same
  storage, a shared database: `Ramal.Storage.ETS` is a table per node, so it only serves a cluster of one.

  When the network splits, each side can load the same branch, one process per side. Every load bumps the branch's
  epoch in the storage, and every write of a process is conditional on the epoch it loaded. The process that lost is
  refused at its next save: it emits `[:ramal, :branch, :fenced]` and stops, and nothing it holds overwrites the newer
  state. A merge it was running is refused too, inside the merge transaction. When the nodes find each other again
  `:global` keeps the process with the higher epoch and stops the other.

  `:global` has a long record of trouble under partial network partitions, where nodes see different subsets of the
  cluster. OTP 25 turned on `prevent_overlapping_partitions` by default, which disconnects nodes to restore a fully
  connected view. By default a name clash after a split is settled by killing one of the two processes; Ramal's
  resolver asks the loser to stop through its own persist path instead, and the storage refuses any save that would
  overwrite the winner. Registration takes a cluster-wide lock, so it costs
  more as the cluster grows. Ramal accepts this because it does not rely on `:global` for safety: `:global` only
  decides which process serves a branch, and the storage's epoch decides which process may write. A process that
  `:global` gets wrong is refused at its next save (ADR 0044).

  The split loses writes. Without `durable: true`, what the losing process held since its last save is lost, and the
  `:fenced` event announces it. A durable branch (`:durable`, ADR 0048) stores each action before the action returns, so
  no acknowledged write is lost, and an action the losing process cannot store fails with `:fenced`. Another node loads
  the branch with every action that ended.

  These stay on the node: the telemetry events (attach handlers on every node), the `:branch_rate` window, and the
  marks of a process killed for its heap, which the other nodes do not see (they load the last saved state, as they
  would after the node crashed). A crash of the node that holds a branch loses its unsaved writes, as on one node,
  unless the branch is durable. `ramal_live`'s inspector shows the events of its own node unless its broadcaster runs
  on every node over a clustered `Phoenix.PubSub`.

  `idle_timeout` and `max_heap_size` belong to the supervisor, not to a branch, because a per-branch value would be
  forgotten when the branch is unloaded and loaded again.

  ## Example

      iex> opts = [storage: Ramal.Storage.ETS, idle_timeout: 1_000, repo: MyApp.Repo]
      iex> config = Ramal.Supervisor.build_config(opts)
      iex> {config.storage, config.idle_timeout, config.storage_config}
      {Ramal.Storage.ETS, 1000, [repo: MyApp.Repo]}
  """

  use Supervisor

  require Logger

  alias Ramal.Ash.Contract
  alias Ramal.Error
  alias Ramal.Storage.ETS
  alias Ramal.Telemetry

  @registry Ramal.Registry
  @dynamic Ramal.BranchSupervisor
  @config_key {__MODULE__, :config}
  @default_idle_timeout :timer.minutes(5)
  @default_max_heap_size 25_000_000

  @type config :: %{
          storage: module,
          cluster: boolean,
          storage_config: keyword,
          idle_timeout: timeout,
          max_heap_size: pos_integer,
          durable: boolean,
          limits: %{max_active: pos_integer | nil, rate: {pos_integer, pos_integer} | nil}
        }

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # init/1 runs in the supervisor process, so the tables are owned by it and live exactly as long as it does.
    create_table(ETS)
    create_table(ETS.writes_table(), :ordered_set)
    create_table(__MODULE__)
    config = build_config(opts)
    check_cluster!(config)
    check_durable!(config)
    check_ash_versions()
    :persistent_term.put(@config_key, config)

    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # A cluster without fencing would let two nodes overwrite each other, so refuse to start rather than run unsafely.
  defp check_cluster!(%{cluster: true, storage: storage}) do
    unless Code.ensure_loaded?(storage) and function_exported?(storage, :claim, 2) do
      raise ArgumentError,
            "Ramal.Supervisor with `cluster: true` needs a storage that fences writes with an epoch " <>
              "(Ramal.Storage `claim/2`), and #{inspect(storage)} does not define it; " <>
              "use Ramal.Storage.Postgres after `mix ramal.gen.migration`"
    end
  end

  defp check_cluster!(_config), do: :ok

  # Every branch would fail to be created, so say so once, at start, instead.
  defp check_durable!(%{durable: true, storage: storage}) do
    unless Ramal.Storage.durable?(storage) do
      raise ArgumentError, Exception.message(Ramal.Storage.durability_unsupported(storage))
    end
  end

  defp check_durable!(_config), do: :ok

  # Ramal runs on Ash internals (Ramal.Ash), so a version outside the range it is tested with may break a branch without
  # a sign. Warn once per start, and outside the range also run the Ash contract (ADR 0049): inside it CI has run the
  # same checks already, so boot costs nothing. Never refuse: the host may be ahead of the range, and the warning is the
  # signal. The broken assumptions are kept, so a branch refuses the work they break.
  defp check_ash_versions do
    ash_boot_check(%{
      ash: Ramal.Ash.installed_version(:ash),
      ash_postgres: Ramal.Ash.installed_version(:ash_postgres)
    })
  end

  # The boot check on the versions it is given; `check_ash_versions/0` passes the loaded ones. It is public only so
  # that a test can run it on versions that are not installed (test/ramal/ash_boot_test.exs).
  @doc false
  @spec ash_boot_check(%{ash: String.t() | nil, ash_postgres: String.t() | nil}) :: :ok
  def ash_boot_check(versions) do
    untested =
      for {app, installed} <- versions,
          {:untested, version, range} <- [Ramal.Ash.check_version(app, installed)] do
        Logger.warning(Ramal.Ash.untested_message(app, version, range))
        app
      end

    if untested == [], do: Contract.put_broken([]), else: check_contract(versions)
  end

  defp check_contract(%{ash: ash, ash_postgres: ash_postgres}) do
    broken = for {id, {:broken, _reason}} <- Contract.run(), do: id
    Contract.put_broken(broken)

    Telemetry.ash_contract(broken, ash, ash_postgres)

    if broken == [] do
      Logger.warning(
        "Ramal's Ash contract passed on ash #{ash}, all #{length(Contract.assumptions())} checks"
      )
    else
      Logger.warning(
        "Ramal's Ash contract is broken on ash #{ash}: #{Enum.join(broken, ", ")}. Branch work that relies on " <>
          "these is refused with :ash_incompatible. Run `mix ramal.doctor` for the reasons."
      )
    end
  end

  defp create_table(name, type \\ :set) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, type, read_concurrency: true])
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
    {known, storage_config} =
      Keyword.split(opts, [
        :storage,
        :cluster,
        :idle_timeout,
        :max_heap_size,
        :durable,
        :max_active_branches,
        :branch_rate
      ])

    %{
      storage: Keyword.get(known, :storage, Ramal.Storage.ETS),
      cluster: Keyword.get(known, :cluster, false) == true,
      storage_config: storage_config,
      idle_timeout: Keyword.get(known, :idle_timeout, @default_idle_timeout),
      max_heap_size: Keyword.get(known, :max_heap_size, @default_max_heap_size),
      durable: Keyword.get(known, :durable, false) == true,
      limits: Ramal.Limits.build(known)
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
  def table, do: __MODULE__

  @doc false
  def registry, do: @registry

  @doc false
  def dynamic_supervisor, do: @dynamic

  @doc false
  def via(id, %{cluster: true}), do: {:via, Ramal.Cluster, id}
  def via(id, _config), do: {:via, Registry, {@registry, id}}

  @doc false
  @spec whereis(String.t()) :: pid | nil
  def whereis(id) do
    case :persistent_term.get(@config_key, nil) do
      %{cluster: true} -> cluster_whereis(id)
      _local -> local_whereis(id)
    end
  end

  defp local_whereis(id) do
    case Registry.lookup(@registry, id) do
      # The Registry drops the entry of a dead process a moment late, so check that the pid is still alive.
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  # `:global` drops the name of a process that died on this node when it sees the exit, which is also a moment late. A
  # pid on another node cannot be checked from here: a call to it that finds it gone is retried like a local one.
  defp cluster_whereis(id) do
    case Ramal.Cluster.whereis_name(id) do
      :undefined -> nil
      pid when node(pid) == node() -> if Process.alive?(pid), do: pid
      pid -> pid
    end
  end

  @doc false
  def mark_too_large(id), do: :ets.insert(__MODULE__, {{:too_large, id}, true})

  @doc false
  def too_large?(id), do: :ets.member(__MODULE__, {:too_large, id})

  @doc false
  def clear_too_large(id), do: :ets.delete(__MODULE__, {:too_large, id})

  # A branch process marks itself running when it starts and clears the mark in terminate/2. A kill skips terminate/2,
  # so a mark without a live process means the process died without persisting, and storage is behind it.
  @doc false
  def mark_running(id), do: :ets.insert(__MODULE__, {{:running, id}, true})

  @doc false
  def running?(id), do: :ets.member(__MODULE__, {:running, id})

  @doc false
  def clear_running(id), do: :ets.delete(__MODULE__, {:running, id})
end
