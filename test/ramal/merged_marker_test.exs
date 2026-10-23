defmodule Ramal.MergedMarkerTest do
  # A merge stores the branch as merged inside its own transaction, so a merge whose transaction committed is never run
  # again, even when the process that ran it died before it finished (#143, ADR 0035). The cases come from the TLA+
  # model in verification/tla (limit-merger-crash.cfg and limit-node-crash.cfg before the fix); every test of a dead
  # merger or a restart here failed before it.
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [eventually: 1, loaded?: 1]

  alias Ramal.Branch.Server
  alias Ramal.Error
  alias Ramal.Storage.{ETS, Postgres}

  @config [repo: TestRepo]

  defp heads, do: Herd |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.head})

  defp branch_with_writes(herds) do
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "M1", head: 1}, authorize?: false)
      Ash.update!(herds.r7, %{head: 77}, authorize?: false)
    end)

    branch
  end

  # What a merge leaves behind when its process dies after the commit and before finish_merge: the branch claimed, and
  # the storage holding it as merged. The process here claims, marks as the transaction does, and ends.
  defp die_after_commit(branch, storage, config) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, claimed} = Server.begin_merge(branch.id)
        :ok = storage.mark_merged(claimed, config)
        send(test, {:marked, self()})
      end)

    assert_receive {:marked, ^pid}
  end

  describe "with ETS storage" do
    setup do
      start_supervised!({Ramal.Supervisor, storage: ETS})
      seeds = Seeds.seed!()
      {:ok, Map.put(seeds, :branch, branch_with_writes(seeds.herds))}
    end

    test "a merge stores the branch as merged before its transaction commits", %{branch: branch} do
      assert {:ok, %{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      assert {:ok, %{status: :merged}} = ETS.fetch(branch.id, [])
      refute loaded?(branch.id)
    end

    test "a failed merge leaves the stored branch open", %{branch: branch, herds: herds} do
      Ash.destroy!(herds.r7, authorize?: false)

      assert {:error, %Error{reason: :merge_failed}} =
               Ramal.merge(branch, authorize?: false, on_stale: :ignore)

      assert {:ok, %{status: :open}} = ETS.fetch(branch.id, [])
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    end

    test "a branch whose merger died after the commit is merged, and refuses a second merge", %{
      branch: branch
    } do
      die_after_commit(branch, ETS, [])

      eventually(fn -> not loaded?(branch.id) end)
      assert {:ok, %{status: :merged}} = Ramal.get(branch.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.merge(branch, authorize?: false)
      assert {:error, %Error{reason: :not_open}} = Ramal.run(branch, fn -> :ok end)
    end

    test "a branch whose merger died before the commit stays open and merges", %{branch: branch} do
      test = self()

      pid =
        spawn(fn ->
          {:ok, _claimed} = Server.begin_merge(branch.id)
          send(test, {:claimed, self()})
        end)

      assert_receive {:claimed, ^pid}

      # The claim is released once the process is seen to be gone.
      eventually(fn -> match?({:ok, %{replayed: 2}}, Ramal.merge(branch, authorize?: false)) end)
      assert %{"M1" => 1, "R7" => 77} = heads()
    end

    test "a merge the marker refuses writes nothing and leaves the branch merged", %{
      branch: branch
    } do
      # The process missed the first merge (its merger died while the commit was in flight) but the storage has it.
      {:ok, open} = Ramal.get(branch.id)
      :ok = ETS.put(%{open | status: :merged}, [])
      before = heads()

      assert {:error, %Error{reason: :not_open, details: %{status: :merged}}} =
               Ramal.merge(branch, authorize?: false, on_stale: :ignore)

      assert heads() == before
      eventually(fn -> not loaded?(branch.id) end)
      assert {:ok, %{status: :merged}} = Ramal.get(branch.id)
    end
  end

  describe "with Postgres storage" do
    setup do
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo})
      seeds = Seeds.seed!()
      {:ok, Map.put(seeds, :branch, branch_with_writes(seeds.herds))}
    end

    test "mark_merged stores the branch as merged once, and refuses it after", %{branch: branch} do
      {:ok, open} = Ramal.get(branch.id)

      assert Postgres.mark_merged(open, @config) == :ok
      assert {:ok, %{status: :merged, log: log}} = Postgres.fetch(branch.id, @config)
      assert log == open.log

      assert {:error, %Error{reason: :not_open, details: %{status: :merged}}} =
               Postgres.mark_merged(open, @config)
    end

    test "the mark rolls back with the merge's transaction", %{branch: branch} do
      {:ok, open} = Ramal.get(branch.id)

      {:error, :rolled_back} =
        TestRepo.transaction(fn ->
          :ok = Postgres.mark_merged(open, @config)
          TestRepo.rollback(:rolled_back)
        end)

      assert {:ok, %{status: :open}} = Postgres.fetch(branch.id, @config)
    end

    test "a merged row is not stored back as open", %{branch: branch} do
      {:ok, open} = Ramal.get(branch.id)
      :ok = Postgres.mark_merged(open, @config)

      assert Postgres.put(open, @config) == :ok
      assert {:ok, %{status: :merged}} = Postgres.fetch(branch.id, @config)

      approved = %{open | status: :merged, metadata: %{decided: true}}
      assert Postgres.put(approved, @config) == :ok
      assert {:ok, %{metadata: %{decided: true}}} = Postgres.fetch(branch.id, @config)
    end

    test "after a restart, a branch whose merge committed before its process ended is merged", %{
      branch: branch
    } do
      die_after_commit(branch, Postgres, @config)

      # The node goes down with the branch process still holding the claimed, open branch.
      stop_supervised!(Ramal.Supervisor)
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo})

      assert {:ok, %{status: :merged}} = Ramal.get(branch.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.merge(branch, authorize?: false)
    end

    test "approve/2 records its decision on the branch the transaction marked", %{branch: branch} do
      {:ok, _} = Ramal.propose(branch, reason: "go")

      assert {:ok, %{branch: approved}} =
               Ramal.approve(branch, decided_by: %{id: 2}, authorize?: false)

      assert {:ok, stored} = Postgres.fetch(branch.id, @config)
      assert stored.status == :merged and stored.proposal == approved.proposal
    end
  end
end
