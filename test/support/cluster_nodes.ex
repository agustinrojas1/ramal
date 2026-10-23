defmodule Ramal.ClusterNodes do
  @moduledoc false
  # Real BEAM nodes for the cluster tests (test/ramal/cluster_nodes_test.exs). Each one is a `:peer` started with this
  # VM's code path, a Repo on the test database without the sandbox (the nodes must see each other's committed rows)
  # and a Ramal.Supervisor with `cluster: true`. The functions below also run on those nodes, which is why they live
  # here and not in the test file: a test module's code is not on the path of the peers.

  alias Ramal.Storage.Postgres
  alias Ramal.Test.Farm
  alias Ramal.Test.Farm.Herd

  @apps [:ash, :ash_postgres, :ramal, :ecto, :ecto_sql, :postgrex]

  @doc "Whether this VM can run distributed, which the tests of a cluster need. Starts distribution when it is off."
  def available? do
    Node.alive?() or start_distribution()
  end

  defp start_distribution do
    start_epmd()
    match?({:ok, _}, Node.start(:"ramal_test_#{System.pid()}@127.0.0.1", :longnames))
  rescue
    _ -> false
  end

  # `epmd` is in the PATH where Erlang is installed by a package manager, and in erts's own bin where it is not.
  defp start_epmd do
    case epmd() do
      nil -> :ok
      epmd -> System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
    end
  end

  @doc "The path of the `epmd` executable this VM can start, or `nil`: erts's own bin first, then the PATH."
  def epmd do
    erts_epmd =
      Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "bin", "epmd"])

    if File.regular?(erts_epmd), do: erts_epmd, else: System.find_executable("epmd")
  end

  @doc "Why `available?/0` is false, for the message of a CI run that cannot skip the cluster tests."
  def unavailable_reason do
    case epmd() do
      nil -> "epmd was not found in erts's bin directory or in the PATH"
      epmd -> "epmd was found at #{epmd}, but Node.start/2 did not start a distributed node"
    end
  end

  @doc """
  Starts a node named after `name`, running `Ramal.Supervisor` with `opts` on the Postgres storage, and returns
  `{peer, node}`. Stop it with `stop/1`: the peer is not linked to the caller, so that a test can still clean up the
  database through the nodes in `on_exit`.

  The test VM talks to a node through the standard input and output of its port (`call/4`), not through distribution:
  a VM joined to the cluster would take part in `:global`, and a test that cuts the link between two nodes would then be
  cut from both by the check that prevents overlapping partitions.
  """
  def start(name, opts \\ []) do
    paths = Enum.map(:code.get_path(), &List.to_charlist/1)

    {:ok, peer, node} =
      :peer.start(%{
        name: ~c"#{name}#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        # `once`: a node connects to another the first time, and not again after a disconnect until it asks to.
        args: [~c"-pa" | paths] ++ [~c"-kernel", ~c"dist_auto_connect", ~c"once"]
      })

    for app <- @apps, {key, value} <- Application.get_all_env(app) do
      :peer.call(peer, Application, :put_env, [app, key, value, [persistent: true]])
    end

    repo_opts = [pool: DBConnection.ConnectionPool, pool_size: 5]
    sup_opts = [storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo, cluster: true] ++ opts
    :ok = :peer.call(peer, __MODULE__, :boot, [repo_opts, sup_opts])
    {peer, node}
  end

  @doc "Stops the node."
  def stop(peer) do
    :peer.stop(peer)
  catch
    :exit, _ -> :ok
  end

  @doc "Runs `module.function(args)` on the node."
  def call(peer, module, function, args \\ []),
    do: :peer.call(peer, module, function, args, 30_000)

  @doc false
  # A process that outlives the call: the repo and the supervisor are linked to it, and it lives as long as the node.
  def boot(repo_opts, sup_opts), do: :proc_lib.start(__MODULE__, :keep, [repo_opts, sup_opts])

  @doc false
  def keep(repo_opts, sup_opts) do
    {:ok, _} = Application.ensure_all_started(:ash_postgres)
    record_events()
    {:ok, _} = Ramal.TestRepo.start_link(repo_opts)
    {:ok, _} = Ramal.Supervisor.start_link(sup_opts)
    # The SQL of every query is logged at debug, which the test config silences on the test VM.
    Logger.configure(level: :warning)
    :proc_lib.init_ack(:ok)
    Process.sleep(:infinity)
  end

  # Keeps the branch events of the node in an ETS table, because the test VM cannot be sent messages (see start/2).
  defp record_events do
    :ets.new(__MODULE__, [:named_table, :public, :ordered_set])

    :telemetry.attach_many(
      __MODULE__,
      Ramal.Telemetry.branch_events(),
      &__MODULE__.record/4,
      nil
    )
  end

  @doc false
  def record(event, _measurements, metadata, _config),
    do: :ets.insert(__MODULE__, {System.unique_integer([:monotonic]), event, metadata})

  @doc "The branch events of the node so far, as `{event, metadata}`, oldest first."
  def events, do: for({_n, event, metadata} <- :ets.tab2list(__MODULE__), do: {event, metadata})

  # -- what the tests ask a node to do ---------------------------------------------------------------------------

  def create_branch, do: Ramal.branch(Farm)

  def create_herd(id, name) do
    Ramal.run(id, fn -> Ash.create!(Herd, %{name: name, head: 1}, authorize?: false) end)
  end

  @doc "Like `create_herd/2`, but the error of an action that failed is returned, with the reason of its `Ramal.Error`."
  def try_create_herd(id, name) do
    case Ramal.run(id, fn -> Ash.create(Herd, %{name: name, head: 1}, authorize?: false) end) do
      {:ok, {:ok, herd}} -> {:ok, herd.name}
      {:ok, {:error, error}} -> {:error, (Ramal.Error.find(error) || error).reason}
      {:error, %Ramal.Error{reason: reason}} -> {:error, reason}
    end
  end

  @doc "The names of the herds the branch created, read from wherever the branch is."
  def created(id) do
    with {:ok, changes} <- Ramal.diff(id) do
      changes |> Enum.map(fn change -> elem(change.changes.name, 1) end) |> Enum.sort()
    end
  end

  def holder(id), do: Ramal.Supervisor.whereis(id)

  @doc "The node whose process holds the branch, or nil."
  def holder_node(id) do
    if pid = holder(id), do: node(pid)
  end

  @doc "The branch as storage holds it, bypassing the process."
  def stored(id) do
    with {:ok, branch} <- Postgres.fetch(id, repo: Ramal.TestRepo) do
      branch.overlay
      |> Map.values()
      |> Enum.map(fn {_kind, record} -> record.name end)
      |> Enum.sort()
    end
  end

  @doc "Connects the node to `other` and waits until `:global` on both has exchanged its names."
  def join(peer, other_peer, other_node) do
    true = call(peer, Node, :connect, [other_node])
    call(peer, :global, :sync, [])
    call(other_peer, :global, :sync, [])
  end

  @doc "Cuts the link between two nodes from both sides. `dist_auto_connect: once` keeps them from reconnecting."
  def split(peer, node, other_peer, other_node) do
    call(peer, Node, :disconnect, [other_node])
    call(other_peer, Node, :disconnect, [node])
    :ok
  end

  def delete_branches(ids) do
    for id <- ids, do: Postgres.delete(id, repo: Ramal.TestRepo)
    :ok
  end
end
