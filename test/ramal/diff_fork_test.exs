defmodule Ramal.DiffForkTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Change

  @admin %{role: :admin}

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp names(herds), do: herds |> Enum.map(& &1.name) |> Enum.sort()
  defp read_names(branch), do: inside(branch, fn -> names(Ash.read!(Herd, authorize?: false)) end)

  defp change_for(changes, resource, key),
    do: Enum.find(changes, &(&1.resource == resource and &1.key == key))

  describe "diff/1" do
    test "an empty branch has no changes", %{branch: branch} do
      assert {:ok, []} = Ramal.diff(branch)
    end

    test "a created row has every attribute as {nil, value}", %{branch: branch} do
      herd =
        inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)

      assert {:ok, [%Change{} = change]} = Ramal.diff(branch)
      assert %{resource: Herd, key: key, kind: :created} = change
      assert key == herd.id
      assert change.changes.name == {nil, "R10"}
      assert change.changes.head == {nil, 5}
      assert change.changes.id == {nil, herd.id}
    end

    test "an updated row lists only the attributes that differ", %{branch: branch, herds: herds} do
      inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)

      assert {:ok, [change]} = Ramal.diff(branch)
      assert %{resource: Herd, kind: :updated} = change
      assert change.changes.head == {30, 31}
      assert Map.has_key?(change.changes, :updated_at)
      refute Map.has_key?(change.changes, :name)
      refute Map.has_key?(change.changes, :inserted_at)
    end

    test "a deleted row has every attribute as {value, nil}", %{branch: branch, herds: herds} do
      inside(branch, fn -> Ash.destroy!(herds.r9, authorize?: false) end)

      assert {:ok, [change]} = Ramal.diff(branch)
      assert %{resource: Herd, kind: :deleted} = change
      assert change.key == herds.r9.id
      assert change.changes.name == {"R9", nil}
      assert change.changes.head == {25, nil}
    end

    test "changes come in the order the branch first touched each row", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        Ash.update!(herds.r8, %{head: 36}, authorize?: false)
        created = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.destroy!(herds.r7, authorize?: false)
        Ash.update!(herds.r8, %{head: 37}, authorize?: false)
        created
      end)

      assert {:ok, changes} = Ramal.diff(branch)
      assert Enum.map(changes, & &1.kind) == [:updated, :created, :deleted]
      assert Enum.at(changes, 0).changes.head == {35, 37}
    end

    test "a row restored to its base values keeps only the attributes that still differ", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        r7 = Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.update!(r7, %{head: 30}, authorize?: false)
      end)

      assert {:ok, changes} = Ramal.diff(branch)
      # updated_at still differs, so the row is a change; head is back to its base value.
      assert [%{kind: :updated, changes: changes}] = changes
      refute Map.has_key?(changes, :head)
    end

    test "a row created and destroyed in the branch leaves no change", %{branch: branch} do
      inside(branch, fn ->
        herd = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.destroy!(herd, authorize?: false)
      end)

      assert {:ok, []} = Ramal.diff(branch)
    end

    test "includes the rows a hook of another action wrote", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)
      end)

      assert {:ok, changes} = Ramal.diff(branch)
      assert Enum.map(changes, &{&1.resource, &1.kind}) == [{Herd, :updated}, {Move, :created}]

      assert change_for(changes, Herd, herds.r7.id).changes.paddock_id ==
               {paddocks.l07.id, paddocks.l18.id}
    end

    test "never queries the database", %{branch: branch, herds: herds} do
      inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      TestRepo.delete_all(Herd)

      assert {:ok, [%{kind: :updated}]} = Ramal.diff(branch)
    end

    test "takes an id as well as a struct", %{branch: branch} do
      assert {:ok, []} = Ramal.diff(branch.id)
      assert {:error, %Ramal.Error{reason: :not_found}} = Ramal.diff(Ash.UUID.generate())
    end
  end

  describe "fingerprints" do
    test "a read records the fingerprint of every base row it returns", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn -> Ash.read!(Herd, authorize?: false) end)

      {:ok, state} = Ramal.get(branch.id)

      assert Map.new(state.base, fn {{Herd, key}, row} -> {key, row} end) ==
               Map.new(herds, fn {_name, herd} ->
                 {herd.id, %{fingerprint: Ramal.Resource.fingerprint(herd), snapshot: nil}}
               end)
    end

    test "a read that selects some attributes records none", %{branch: branch} do
      inside(branch, fn -> Ash.read!(Ash.Query.select(Herd, [:name]), authorize?: false) end)

      assert {:ok, %{base: base}} = Ramal.get(branch.id)
      assert base == %{}
    end

    test "the fingerprint of the first read is kept when the row is written later", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        [r7] = Ash.read!(Ash.Query.filter(Herd, name == "R7"), authorize?: false)
        Ash.update!(r7, %{head: 31}, authorize?: false)
      end)

      {:ok, state} = Ramal.get(branch.id)

      assert %{fingerprint: fingerprint, snapshot: %Herd{head: 30}} =
               state.base[{Herd, herds.r7.id}]

      assert fingerprint == Ramal.Resource.fingerprint(herds.r7)
    end

    test "a write without an earlier read fingerprints the row as the action found it", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)

      {:ok, state} = Ramal.get(branch.id)
      assert state.base[{Herd, herds.r7.id}].fingerprint == Ramal.Resource.fingerprint(herds.r7)
    end
  end

  describe "fork/2" do
    test "starts with the parent's changes as of the fork", %{branch: branch, herds: herds} do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.destroy!(herds.r9, authorize?: false)
      end)

      assert {:ok, fork} = Ramal.fork(branch)
      assert read_names(fork) == ["R10", "R7", "R8"]
      assert read_names(branch) == ["R10", "R7", "R8"]
    end

    test "sees nothing the parent does afterwards, and the parent nothing of the fork", %{
      branch: branch,
      herds: herds
    } do
      {:ok, fork} = Ramal.fork(branch)

      inside(branch, fn -> Ash.destroy!(herds.r7, authorize?: false) end)
      inside(fork, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)

      assert read_names(branch) == ["R8", "R9"]
      assert read_names(fork) == ["R10", "R7", "R8", "R9"]
    end

    test "the database stays untouched by either branch", %{branch: branch, herds: herds} do
      {:ok, fork} = Ramal.fork(branch)
      inside(fork, fn -> Ash.update!(herds.r7, %{head: 99}, authorize?: false) end)

      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 30
    end

    test "diff on a fork includes the inherited changes", %{branch: branch, herds: herds} do
      inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      {:ok, fork} = Ramal.fork(branch)
      inside(fork, fn -> Ash.destroy!(herds.r9, authorize?: false) end)

      assert {:ok, fork_changes} = Ramal.diff(fork)

      assert Enum.map(fork_changes, &{&1.kind, &1.key}) == [
               {:updated, herds.r7.id},
               {:deleted, herds.r9.id}
             ]

      assert {:ok, [%{kind: :updated}]} = Ramal.diff(branch)
    end

    test "the fork is a new open branch that records where it came from", %{branch: branch} do
      {:ok, parent} = Ramal.get(branch.id)

      assert {:ok, fork} = Ramal.fork(branch, name: "variant")
      assert fork.id != branch.id
      assert fork.name == "variant"
      assert fork.status == :open
      assert fork.metadata.forked_from == branch.id
      assert {:ok, ^fork} = Ramal.get(fork.id)
      assert {:ok, ^parent} = Ramal.get(branch.id)
    end

    test "forks of forks keep inheriting", %{branch: branch, herds: herds} do
      inside(branch, fn -> Ash.destroy!(herds.r7, authorize?: false) end)
      {:ok, fork} = Ramal.fork(branch)
      {:ok, grandchild} = Ramal.fork(fork)

      assert read_names(grandchild) == ["R8", "R9"]
      assert {:ok, [%{kind: :deleted}]} = Ramal.diff(grandchild)
    end

    test "emits [:ramal, :branch, :fork] with the parent id", %{branch: branch} do
      test = self()
      handler = "fork-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ramal, :branch, :fork],
        fn _event, _measurements, metadata, _config -> send(test, {:forked, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, fork} = Ramal.fork(branch)
      branch_id = branch.id
      fork_id = fork.id

      assert_receive {:forked, %{branch_id: ^fork_id, parent_id: ^branch_id, domain: Farm}}
    end

    test "refuses a branch that is not open and one that does not exist", %{branch: branch} do
      :ok = Ramal.discard(branch)

      assert {:error, %Ramal.Error{reason: :not_open}} = Ramal.fork(branch)
      assert {:error, %Ramal.Error{reason: :not_found}} = Ramal.fork(Ash.UUID.generate())
    end

    test "works on a branch whose process is not running", %{branch: branch, herds: herds} do
      inside(branch, fn -> Ash.destroy!(herds.r7, authorize?: false) end)
      stop_process(branch.id)

      assert {:ok, fork} = Ramal.fork(branch.id)
      assert read_names(fork) == ["R8", "R9"]
    end
  end

  # Not a discard: the branch is persisted on shutdown and rehydrated by the next call.
  defp stop_process(id) do
    pid = Ramal.Supervisor.whereis(id)
    ref = Process.monitor(pid)
    GenServer.stop(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end
end
