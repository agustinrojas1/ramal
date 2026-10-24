defmodule Ramal.StaleCheckTest do
  # A host that commits through its own command layer (#208, ADR 0051): the staleness check on its own, in the host's
  # transaction, and the branch stored as merged afterwards. Ramal.Supervisor is one per node, so not async.
  use Ramal.DataCase, async: false

  alias Ramal.Error
  alias Ramal.Test.Farm.Commands

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)

    # The host's what-if: the command runs in the branch, which reads the herd, the paddock and the herds in it.
    Ramal.run!(branch, fn ->
      assert {:ok, %{from_paddock_id: from}} =
               Commands.move_herd(seeds.herds.r7.id, seeds.paddocks.l18.id)

      assert from == seeds.paddocks.l07.id
    end)

    {:ok, Map.put(seeds, :branch, branch)}
  end

  # The host's commit: check with locks, run the commands, all in one transaction.
  defp commit(branch, seeds) do
    Ash.transact([Herd, Paddock, Move], fn ->
      case Ramal.stale(branch, lock: true) do
        {:ok, []} -> Commands.move_herd(seeds.herds.r7.id, seeds.paddocks.l18.id)
        {:ok, rows} -> {:stale, rows}
      end
    end)
  end

  # What the database holds, without ids and timestamps.
  defp snapshot do
    herds = Herd |> Ash.read!(authorize?: false) |> Enum.map(&{&1.name, &1.head, &1.paddock_id})

    moves =
      Move
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.herd_id, &1.from_paddock_id, &1.to_paddock_id, &1.moved_on})

    {Enum.sort(herds), Enum.sort(moves)}
  end

  # Runs `fun` and rolls it back, returning the snapshot it left.
  defp rolled_back(fun) do
    {:error, state} =
      TestRepo.transaction(fn ->
        fun.()
        TestRepo.rollback(snapshot())
      end)

    state
  end

  test "a row the branch read that the base changed is stale", %{herds: herds, branch: branch} do
    Ash.update!(herds.r9, %{head: 50}, authorize?: false)

    assert {:ok, [%{resource: Herd, key: key, reason: :changed}]} = Ramal.stale(branch)
    assert key == herds.r9.id
  end

  test "a row the branch read that the base deleted is stale as deleted", %{
    herds: herds,
    branch: branch
  } do
    Ash.destroy!(herds.r7, authorize?: false)

    assert {:ok, [%{resource: Herd, key: key, reason: :deleted}]} = Ramal.stale(branch)
    assert key == herds.r7.id
  end

  test "stale returns nothing when the base did not move, and leaves the branch open", %{
    branch: branch
  } do
    assert {:ok, []} = Ramal.stale(branch)
    assert {:ok, []} = Ramal.stale(branch)
    assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    assert {:ok, %{replayed: _}} = Ramal.merge(branch, authorize?: false)
  end

  test "stale and merge report the same rows", %{herds: herds, branch: branch} do
    Ash.update!(herds.r9, %{head: 50}, authorize?: false)

    assert {:ok, rows} = Ramal.stale(branch)

    assert {:error, %Error{reason: :stale, details: %{rows: ^rows}}} =
             Ramal.merge(branch, authorize?: false)
  end

  test "a host that replays its commands after a clean check gets what merge would have written",
       seeds do
    {:ok, twin} = Ramal.branch(Farm)

    Ramal.run!(twin, fn ->
      {:ok, _undo} = Commands.move_herd(seeds.herds.r7.id, seeds.paddocks.l18.id)
    end)

    by_merge = rolled_back(fn -> {:ok, _result} = Ramal.merge(twin, authorize?: false) end)
    by_host = rolled_back(fn -> {:ok, {:ok, %{herd_id: _}}} = commit(seeds.branch, seeds) end)

    assert by_host == by_merge
    assert {[_, _, _], [_one_move]} = by_host
  end

  test "a host whose check finds a stale row runs no command", seeds do
    Ash.update!(seeds.herds.r9, %{head: 50}, authorize?: false)
    before = snapshot()

    assert {:ok, {:stale, [%{resource: Herd}]}} = commit(seeds.branch, seeds)
    assert snapshot() == before
  end

  describe "locks" do
    # The `FOR UPDATE` statements on the herds table that `fun` makes.
    defp locking_selects(fun) do
      test = self()
      handler = "locks-#{inspect(test)}"

      :telemetry.attach(
        handler,
        [:ramal, :test_repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if query =~ ~r/FROM "herds".*FOR UPDATE/s, do: send(test, :locked)
        end,
        nil
      )

      try do
        fun.()
        flush(0)
      after
        :telemetry.detach(handler)
      end
    end

    defp flush(count) do
      receive do
        :locked -> flush(count + 1)
      after
        0 -> count
      end
    end

    test "lock: true reads the rows FOR UPDATE, as the merge does", %{branch: branch} do
      assert locking_selects(fn ->
               TestRepo.transaction(fn -> Ramal.stale(branch, lock: true) end)
             end) == 1
    end

    test "without lock the rows are read without locks", %{branch: branch} do
      assert locking_selects(fn -> Ramal.stale(branch) end) == 0
    end

    test "lock: true outside a transaction is refused, as the locks would not outlast the call",
         %{branch: branch} do
      assert {:error, %Error{reason: :not_in_transaction, details: %{resources: resources}}} =
               Ramal.stale(branch, lock: true)

      assert Herd in resources
    end
  end

  describe "mark_merged" do
    test "stores the branch as merged, so list shows it and it cannot be merged again", %{
      branch: branch
    } do
      assert {:ok, %Ramal.Branch{status: :merged}} = Ramal.mark_merged(branch)

      assert {:ok, %{status: :merged}} = Ramal.get(branch.id)
      assert {:ok, listed} = Ramal.list(Farm, status: :merged)
      assert branch.id in Enum.map(listed, & &1.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.merge(branch, authorize?: false)
      assert {:error, %Error{reason: :not_open}} = Ramal.stale(branch)
      assert {:error, %Error{reason: :not_open}} = Ramal.mark_merged(branch)
    end

    test "writes nothing to the base", %{branch: branch} do
      before = snapshot()
      assert {:ok, _branch} = Ramal.mark_merged(branch)
      assert snapshot() == before
    end

    test "does not take a discarded branch", %{branch: branch} do
      :ok = Ramal.discard(branch)
      assert {:error, %Error{reason: :not_open}} = Ramal.mark_merged(branch)
    end
  end

  describe "a proposed branch" do
    setup %{branch: branch} do
      {:ok, _} = Ramal.propose(branch, proposed_by: "ana", reason: "count")
      :ok
    end

    test "stale/2 checks it, with and without locks", %{branch: branch, herds: herds} do
      assert {:ok, []} = Ramal.stale(branch)
      assert {:ok, {:ok, []}} = TestRepo.transaction(fn -> Ramal.stale(branch, lock: true) end)

      assert locking_selects(fn ->
               TestRepo.transaction(fn -> Ramal.stale(branch, lock: true) end)
             end) == 1

      Ash.update!(herds.r9, %{head: 50}, authorize?: false)
      assert {:ok, [%{resource: Herd, reason: :changed}]} = Ramal.stale(branch)
      assert {:ok, %{status: :proposed}} = Ramal.get(branch.id)
    end

    test "mark_merged/2 stores it as merged with the decision recorded", %{branch: branch} do
      test = self()

      :telemetry.attach_many(
        "mark-merged-#{inspect(test)}",
        [[:ramal, :branch, :mark_merged], [:ramal, :branch, :approve]],
        fn event, _measurements, %{branch_id: id}, _config -> send(test, {:event, event, id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("mark-merged-#{inspect(test)}") end)
      before = snapshot()

      assert {:ok, %Ramal.Branch{status: :merged, proposal: %{decision: decision}}} =
               Ramal.mark_merged(branch, decided_by: "bo", reason: "committed by hand")

      assert %{status: :approved, by: "bo", reason: "committed by hand", replayed: 0, stale: []} =
               decision

      assert %DateTime{} = decision.at
      assert snapshot() == before

      assert_received {:event, [:ramal, :branch, :mark_merged], id} when id == branch.id
      assert_received {:event, [:ramal, :branch, :approve], id} when id == branch.id

      assert {:ok, %{status: :merged, proposal: %{decision: %{status: :approved}}}} =
               Ramal.get(branch.id)

      assert {:ok, listed} = Ramal.list(Farm, status: :merged)
      assert branch.id in Enum.map(listed, & &1.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.mark_merged(branch)
      assert {:error, %Error{reason: :not_open}} = Ramal.approve(branch, authorize?: false)
    end

    test "a rejected branch is not taken", %{branch: branch} do
      {:ok, _} = Ramal.reject(branch, decided_by: "bo")
      assert {:error, %Error{reason: :not_open}} = Ramal.mark_merged(branch)
      assert {:error, %Error{reason: :not_open}} = Ramal.stale(branch)
    end
  end

  describe "a nested fork" do
    test "merges into its parent, so neither call applies", %{branch: branch} do
      {:ok, fork} = Ramal.fork(branch, nested: true)

      assert {:error, %Error{reason: :nested_fork}} = Ramal.stale(fork)
      assert {:error, %Error{reason: :nested_fork}} = Ramal.mark_merged(fork)
      assert {:ok, %{status: :open}} = Ramal.get(fork.id)
    end
  end

  test "stale inside Ramal.run/2 is refused like merge", %{branch: branch} do
    assert {:ok, {:error, %Error{reason: :nested_branch}}} =
             Ramal.run(branch, fn -> Ramal.stale(branch) end)
  end
end
