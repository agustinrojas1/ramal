defmodule Ramal.ClusterTest do
  # `cluster: true` on a single node: branch processes are named with :global and every load takes an epoch the storage
  # fences writes with (ADR 0044). Two loads of one branch are made by claiming it from the storage directly, which is
  # what a second node does; test/ramal/cluster_nodes_test.exs does it with real nodes. The ETS storage keeps the epochs
  # in this VM, so these tests need no database but the merge's.
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [capture_branch_events: 0, eventually: 1, loaded?: 1]

  alias Ramal.Branch.Server
  alias Ramal.Cluster
  alias Ramal.Error
  alias Ramal.Storage.ETS
  alias Ramal.Test.EpochHolder

  defp start_cluster(opts \\ []) do
    start_supervised!({Ramal.Supervisor, [cluster: true] ++ opts})
  end

  defp heads, do: Herd |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.head})

  describe "the supervisor" do
    test "names branch processes with :global and keeps the Registry out of it" do
      start_cluster()
      {:ok, branch} = Ramal.branch(Farm)

      pid = Ramal.Supervisor.whereis(branch.id)
      assert is_pid(pid)
      assert :global.whereis_name({Ramal.Branch, branch.id}) == pid
      assert Registry.lookup(Ramal.Supervisor.registry(), branch.id) == []
    end

    test "without cluster: true it keeps using the Registry" do
      start_supervised!(Ramal.Supervisor)
      {:ok, branch} = Ramal.branch(Farm)

      assert [{pid, _}] = Registry.lookup(Ramal.Supervisor.registry(), branch.id)
      assert Ramal.Supervisor.whereis(branch.id) == pid
      assert :global.whereis_name({Ramal.Branch, branch.id}) == :undefined
      assert {:ok, %{epoch: nil}} = Ramal.get(branch.id)
    end

    test "refuses to start with a storage that cannot fence writes" do
      Process.flag(:trap_exit, true)

      assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
               start_supervised({Ramal.Supervisor, cluster: true, storage: Ramal.Storage})

      assert message =~ "claim/2"
    end
  end

  describe "the epoch of a process" do
    test "is the one it claimed when it loaded, and a new load takes the next" do
      start_cluster(idle_timeout: 50)
      {:ok, branch} = Ramal.branch(Farm)

      assert {:ok, %{epoch: 1}} = Ramal.get(branch.id)
      eventually(fn -> not loaded?(branch.id) end)
      assert {:ok, %{epoch: 2}} = Ramal.get(branch.id)
    end

    test "is not inherited by a fork, which claims its own" do
      start_cluster()
      {:ok, branch} = Ramal.branch(Farm)
      {:ok, _} = Ramal.get(branch.id)
      {:ok, fork} = Ramal.fork(branch)

      assert fork.epoch == nil
      assert {:ok, %{epoch: 1}} = Ramal.get(fork.id)
      assert {:ok, %{epoch: 1}} = Ramal.get(branch.id)
    end

    test "is left out of what is stored" do
      start_cluster(idle_timeout: 50)
      {:ok, branch} = Ramal.branch(Farm)
      {:ok, _} = Ramal.get(branch.id)

      eventually(fn -> not loaded?(branch.id) end)
      assert {:ok, %{epoch: nil}} = ETS.fetch(branch.id, [])
    end
  end

  describe "a process that lost the branch to another load" do
    setup do
      capture_branch_events()
      start_cluster(idle_timeout: 150)
      {:ok, branch} = Ramal.branch(Farm, name: "mine")
      Ramal.run!(branch, fn -> Ash.create!(Herd, %{name: "lost", head: 1}, authorize?: false) end)
      {:ok, held} = Ramal.get(branch.id)

      # What another node does after a netsplit: load the branch from the storage and save its own work.
      {:ok, other} = ETS.claim(branch.id, [])
      :ok = ETS.put(%{other | name: "theirs"}, [])
      {:ok, branch: branch, held: held}
    end

    test "is refused at its next save, says so, and stops without overwriting", %{
      branch: branch,
      held: held
    } do
      id = branch.id
      assert held.epoch == 1

      assert_receive {:telemetry, [:ramal, :branch, :fenced],
                      %{branch_id: ^id, epoch: 1, error: error}},
                     2_000

      assert %Error{reason: :fenced} = error
      eventually(fn -> not loaded?(id) end)

      assert {:ok, %{name: "theirs", log: []}} = ETS.fetch(id, [])
      refute_received {:telemetry, [:ramal, :branch, :unload], %{branch_id: ^id}}
      refute_received {:telemetry, [:ramal, :branch, :persist_failed], %{branch_id: ^id}}
    end

    test "cannot propose, and the proposal is not stored", %{branch: branch} do
      assert {:error, %Error{reason: :fenced}} = Ramal.propose(branch)

      eventually(fn -> not loaded?(branch.id) end)
      assert {:ok, %{status: :open, name: "theirs"}} = ETS.fetch(branch.id, [])
    end

    test "cannot discard, and the stored branch is left open", %{branch: branch} do
      assert {:error, %Error{reason: :fenced}} = Ramal.discard(branch)

      eventually(fn -> not loaded?(branch.id) end)
      assert {:ok, %{status: :open}} = ETS.fetch(branch.id, [])
    end

    test "cannot merge: the transaction is rolled back and nothing reaches the database", %{
      branch: branch
    } do
      before = heads()

      assert {:error, %Error{reason: :fenced}} = Ramal.merge(branch, authorize?: false)

      assert heads() == before
      assert {:ok, %{status: :open}} = ETS.fetch(branch.id, [])
    end
  end

  describe "nested forks" do
    test "merge into a parent that a cluster process serves, and the parent persists on its epoch" do
      start_cluster()
      {:ok, parent} = Ramal.branch(Farm, name: "parent")
      {:ok, child} = Ramal.fork(parent, nested: true)

      Ramal.run!(child, fn -> Ash.create!(Herd, %{name: "nested", head: 3}, authorize?: false) end)

      assert {:ok, %{replayed: 1}} = Ramal.merge(child, authorize?: false)

      assert {:ok, %{epoch: epoch, merged_children: [id]}} = Ramal.get(parent.id)
      assert id == child.id
      assert {:ok, %{merged_children: [^id]}} = ETS.fetch(parent.id, [])
      assert epoch == 1
      assert heads() == %{}
    end

    test "cannot merge into a parent that another load fenced: the parent says so and stops" do
      capture_branch_events()
      start_cluster()
      {:ok, parent} = Ramal.branch(Farm, name: "parent")
      {:ok, child} = Ramal.fork(parent, nested: true)

      Ramal.run!(child, fn -> Ash.create!(Herd, %{name: "nested", head: 3}, authorize?: false) end)

      {:ok, _held} = Ramal.get(parent.id)

      {:ok, other} = ETS.claim(parent.id, [])
      :ok = ETS.put(%{other | name: "theirs"}, [])

      assert {:error, %Error{reason: :fenced}} = Ramal.merge(child, authorize?: false)

      id = parent.id
      assert_receive {:telemetry, [:ramal, :branch, :fenced], %{branch_id: ^id}}, 2_000
      eventually(fn -> not loaded?(id) end)
      assert {:ok, %{name: "theirs", merged_children: []}} = ETS.fetch(id, [])
      assert {:ok, %{status: :open}} = Ramal.get(child.id)
    end
  end

  describe "a process whose name :global gave to another" do
    test "saves what it holds and unloads when it is told it was superseded" do
      capture_branch_events()
      start_cluster()
      {:ok, branch} = Ramal.branch(Farm)
      id = branch.id
      Ramal.run!(branch, fn -> Ash.create!(Herd, %{name: "kept", head: 1}, authorize?: false) end)

      GenServer.cast(Ramal.Supervisor.whereis(id), :superseded)

      assert_receive {:telemetry, [:ramal, :branch, :unload],
                      %{branch_id: ^id, reason: :superseded}}

      assert {:ok, %{log: [_one]}} = ETS.fetch(id, [])
    end
  end

  describe "Ramal.Cluster.resolve/3" do
    defp holder(epoch) do
      {:ok, pid} = EpochHolder.start_link({epoch, self()})
      pid
    end

    test "keeps the process with the higher epoch and tells the other to stop" do
      low = holder(1)
      high = holder(3)

      assert Cluster.resolve({Ramal.Branch, "b"}, low, high) == high
      assert_receive {:superseded, ^low}
      refute_received {:superseded, ^high}
    end

    test "keeps the first when both have the same epoch" do
      first = holder(2)
      second = holder(2)

      assert Cluster.resolve({Ramal.Branch, "b"}, first, second) == first
      assert_receive {:superseded, ^second}
    end

    test "treats a process that does not answer as the one with no epoch" do
      alive = holder(1)
      dead = holder(5)
      Process.unlink(dead)
      Process.exit(dead, :kill)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert Cluster.resolve({Ramal.Branch, "b"}, dead, alive) == alive
    end
  end

  test "a branch works through :global as it does through the Registry" do
    start_cluster()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn -> Ash.create!(Herd, %{name: "H1", head: 4}, authorize?: false) end)

    assert {:ok, [%{kind: :created}]} = Ramal.diff(branch)
    assert Server.status(branch.id) == {:ok, :open}
  end
end
