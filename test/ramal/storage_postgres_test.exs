defmodule Ramal.Storage.PostgresTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [crash: 1, eventually: 1, loaded?: 1]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ramal.{Branch, Error}
  alias Ramal.Storage.Codec
  alias Ramal.Storage.Postgres

  doctest Ramal.Storage.Postgres

  @config [repo: TestRepo]

  defp branch(attrs \\ []) do
    struct(Branch.new(Farm, name: "stored"), attrs)
  end

  describe "the storage callbacks" do
    test "a stored branch is fetched back unchanged", %{} do
      herd = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)

      branch =
        branch(
          overlay: %{{Herd, herd.id} => {:created, herd}},
          base: %{{Herd, herd.id} => %{fingerprint: 77, snapshot: nil}},
          log: [
            {:create, Herd, :create, %{name: "R10", head: 5}, nil, [key: herd.id],
             DateTime.utc_now()}
          ],
          metadata: %{ticket: 42}
        )

      assert Postgres.put(branch, @config) == :ok
      assert Postgres.fetch(branch.id, @config) == {:ok, branch}
    end

    test "names, metadata and ids are bound parameters, never part of the SQL" do
      hostile = "x'); DROP TABLE ramal_branches; --"
      branch = %{branch() | name: hostile, metadata: %{note: hostile}}

      assert Postgres.put(branch, @config) == :ok
      assert Postgres.fetch(branch.id, @config) == {:ok, branch}

      for id <- [hostile, "' OR '1'='1", branch.id <> "; DELETE FROM ramal_branches", ""] do
        assert {:error, %Error{reason: :not_found}} = Postgres.fetch(id, @config)
        assert {:error, %Error{reason: :storage}} = Postgres.delete(id, @config)
      end

      assert {:ok, [^branch]} = Postgres.list(Farm, [status: :open], @config)
      assert {:ok, []} = Postgres.list(Farm, [status: :merged], @config)
    end

    test "putting again replaces the row" do
      branch = branch()
      :ok = Postgres.put(branch, @config)
      :ok = Postgres.put(%{branch | name: "renamed", status: :merged}, @config)

      assert {:ok, %{name: "renamed", status: :merged}} = Postgres.fetch(branch.id, @config)
      assert {:ok, [_one]} = Postgres.list(Farm, [], @config)
    end

    test "list skips a row it cannot decode and announces it; fetch still reports the error" do
      good = branch()
      bad = branch(name: "damaged")
      :ok = Postgres.put(good, @config)
      :ok = Postgres.put(bad, @config)
      {:ok, uuid} = Ecto.UUID.dump(bad.id)
      SQL.query!(TestRepo, "UPDATE ramal_branches SET state = '{}'::jsonb WHERE id = $1", [uuid])

      :telemetry.attach(
        "unreadable-test",
        [:ramal, :storage, :unreadable],
        fn _event, _measurements, metadata, pid -> send(pid, {:unreadable, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("unreadable-test") end)

      assert {:ok, [^good]} = Postgres.list(Farm, [], @config)
      assert_received {:unreadable, %{branch_id: id, domain: Farm, message: message}}
      assert id == bad.id
      refute message =~ "{}"
      assert {:error, %Error{reason: :storage}} = Postgres.fetch(bad.id, @config)
    end

    test "an unknown id and an id that is not a UUID are both :not_found" do
      assert {:error, %Error{reason: :not_found}} = Postgres.fetch(Ash.UUID.generate(), @config)

      assert {:error, %Error{reason: :not_found, details: %{id: "nope"}}} =
               Postgres.fetch("nope", @config)
    end

    test "deleting removes the row, and deleting a missing one is fine" do
      branch = branch()
      :ok = Postgres.put(branch, @config)

      assert Postgres.delete(branch.id, @config) == :ok
      assert {:error, %Error{reason: :not_found}} = Postgres.fetch(branch.id, @config)
      assert Postgres.delete(branch.id, @config) == :ok
    end

    test "list returns the branches of one domain, oldest first, optionally by status" do
      older = branch(inserted_at: ~U[2026-01-01 00:00:00.000000Z])
      newer = branch(inserted_at: ~U[2026-02-01 00:00:00.000000Z], status: :merged)
      other = %{Branch.new(Ramal.Test.Other) | inserted_at: ~U[2026-03-01 00:00:00.000000Z]}
      for b <- [newer, older, other], do: :ok = Postgres.put(b, @config)

      assert Postgres.list(Farm, [], @config) == {:ok, [older, newer]}
      assert Postgres.list(Farm, [status: :merged], @config) == {:ok, [newer]}
      assert Postgres.list(Farm, [status: :open], @config) == {:ok, [older]}
      assert Postgres.list(Ramal.Test.Other, [], @config) == {:ok, [other]}
    end

    test "count returns how many branches of one domain have one of the statuses" do
      open = branch()
      proposed = branch(status: :proposed)
      merged = branch(status: :merged)
      other = Branch.new(Ramal.Test.Other)
      for b <- [open, proposed, merged, other], do: :ok = Postgres.put(b, @config)

      assert Postgres.count(Farm, [:open, :proposed], @config) == {:ok, 2}
      assert Postgres.count(Farm, [:merged], @config) == {:ok, 1}
      assert Postgres.count(Farm, [:discarded], @config) == {:ok, 0}
      assert Postgres.count(Farm, [], @config) == {:ok, 0}
      assert Postgres.count(Ramal.Test.Other, [:open], @config) == {:ok, 1}
      assert {:error, %Error{reason: :storage}} = Postgres.count(Farm, [:open], [])
    end

    test "a status or domain that is not an atom is a :storage error, not a raise" do
      assert {:error, %Error{reason: :storage, message: message}} =
               Postgres.list(Farm, [status: "open"], @config)

      assert message =~ ":open"
      assert {:error, %Error{reason: :storage}} = Postgres.count(Farm, ["open"], @config)
      assert {:error, %Error{reason: :storage}} = Postgres.list("Farm", [], @config)
      assert {:error, %Error{reason: :storage}} = Postgres.list(Farm, [owner: self()], @config)
    end

    test "a missing :repo is a :storage error that says how to configure it" do
      assert {:error, %Error{reason: :storage, message: message}} = Postgres.put(branch(), [])
      assert message =~ "repo: MyApp.Repo"
    end

    test "a branch id that is not a UUID cannot be stored" do
      assert {:error, %Error{reason: :storage, message: message}} =
               Postgres.put(branch(id: "b1"), @config)

      assert message =~ "UUID"
    end

    test "a value that cannot be stored fails the put and leaves the table alone" do
      bad = branch(metadata: %{pid: self()})

      assert {:error, %Error{reason: :storage}} = Postgres.put(bad, @config)
      assert {:error, %Error{reason: :not_found}} = Postgres.fetch(bad.id, @config)
    end
  end

  describe "the write log" do
    defp durable(wal \\ 0), do: branch(durable: true, wal: wal)

    defp delta(n),
      do: %{overlay: %{}, gone: [{Herd, n}], base: %{}, log: [], seen: %{}, next_placeholder: 0}

    defp stored_seqs(branch) do
      {:ok, id} = Ecto.UUID.dump(branch.id)

      %{rows: rows} =
        SQL.query!(
          TestRepo,
          "SELECT seq FROM ramal_branch_writes WHERE branch_id = $1 ORDER BY seq",
          [id]
        )

      List.flatten(rows)
    end

    defp stored(branch) do
      branch = branch
      :ok = Postgres.put(branch, @config)
      branch
    end

    defp append_all(branch, seqs),
      do: for(seq <- seqs, do: :ok = Postgres.append(branch, seq, delta(seq), @config))

    test "the deltas after the branch's wal come back oldest first, decoded" do
      branch = stored(durable())
      append_all(branch, [3, 1, 2])

      assert Postgres.writes_after(branch, @config) ==
               {:ok, [{1, delta(1)}, {2, delta(2)}, {3, delta(3)}]}

      assert Postgres.writes_after(%{branch | wal: 2}, @config) == {:ok, [{3, delta(3)}]}
      assert Postgres.writes_after(%{branch | wal: 3}, @config) == {:ok, []}
    end

    test "the deltas of another branch are not returned" do
      one = stored(durable())
      other = stored(durable())
      append_all(one, [1, 2])
      append_all(other, [1])

      assert {:ok, [{1, _}, {2, _}]} = Postgres.writes_after(one, @config)
      assert {:ok, [{1, _}]} = Postgres.writes_after(other, @config)
    end

    test "a delta is not stored twice under one number" do
      branch = stored(durable())
      append_all(branch, [1])

      assert {:error, %Error{reason: :storage}} = Postgres.append(branch, 1, delta(1), @config)
      assert stored_seqs(branch) == [1]
    end

    test "putting a durable branch deletes the deltas its wal covers, and only those" do
      branch = stored(durable())
      append_all(branch, [1, 2, 3])

      assert Postgres.put(%{branch | wal: 2}, @config) == :ok

      assert stored_seqs(branch) == [3]
      assert {:ok, %{wal: 2, durable: true}} = Postgres.fetch(branch.id, @config)
    end

    test "putting a branch that is not durable does not touch the table" do
      branch = stored(durable())
      append_all(branch, [1])

      assert Postgres.put(%{branch | durable: false, wal: 5}, @config) == :ok
      assert stored_seqs(branch) == [1]
    end

    test "deleting a branch deletes its log" do
      branch = stored(durable())
      other = stored(durable())
      append_all(branch, [1, 2])
      append_all(other, [1])

      assert Postgres.delete(branch.id, @config) == :ok

      assert stored_seqs(branch) == []
      assert stored_seqs(other) == [1]
    end

    test "a delta of a branch that is not stored is refused" do
      assert {:error, %Error{reason: :storage}} = Postgres.append(durable(), 1, delta(1), @config)
    end

    test "a delta that cannot be stored fails and stores nothing" do
      branch = stored(durable())
      entry = {:create, Herd, :create, %{pid: self()}, nil, [key: "k"], DateTime.utc_now()}
      bad = %{overlay: %{}, gone: [], base: %{}, log: [entry], seen: %{}, next_placeholder: 0}

      assert {:error, %Error{reason: :storage}} = Postgres.append(branch, 1, bad, @config)
      assert stored_seqs(branch) == []
    end

    test "a missing :repo or a branch id that is not a UUID is a :storage error" do
      assert {:error, %Error{reason: :storage, message: message}} =
               Postgres.append(durable(), 1, delta(1), [])

      assert message =~ "repo: MyApp.Repo"
      assert {:error, %Error{reason: :storage}} = Postgres.writes_after(branch(id: "b1"), @config)
    end
  end

  describe "the write log of a branch with an epoch" do
    setup do
      branch = stored(durable())
      {:ok, branch: branch}
    end

    test "the holder of the current epoch appends and reads the log", %{branch: branch} do
      {:ok, held} = Postgres.claim(branch.id, @config)

      assert Postgres.append(held, 1, delta(1), @config) == :ok
      assert Postgres.writes_after(held, @config) == {:ok, [{1, delta(1)}]}
    end

    test "the write log of a branch that was deleted after its claim is :not_found, not an empty log",
         %{branch: branch} do
      {:ok, held} = Postgres.claim(branch.id, @config)
      :ok = Postgres.delete(branch.id, @config)

      assert {:error, %Error{reason: :not_found}} = Postgres.writes_after(held, @config)
    end

    test "the holder of an older epoch is refused, stores nothing, and cannot read the log", %{
      branch: branch
    } do
      {:ok, old} = Postgres.claim(branch.id, @config)
      :ok = Postgres.append(old, 1, delta(1), @config)
      {:ok, newer} = Postgres.claim(branch.id, @config)

      assert {:error, %Error{reason: :fenced, details: %{epoch: 1}}} =
               Postgres.append(old, 2, delta(2), @config)

      assert {:error, %Error{reason: :fenced}} = Postgres.writes_after(old, @config)
      assert stored_seqs(branch) == [1]

      # What the next holder reads is what the earlier one was told was stored, and nothing it was refused.
      assert Postgres.writes_after(newer, @config) == {:ok, [{1, delta(1)}]}
      assert Postgres.append(newer, 2, delta(3), @config) == :ok
      assert stored_seqs(branch) == [1, 2]
    end

    test "a snapshot of the older holder deletes no delta, and the holder's deletes the ones it covers",
         %{
           branch: branch
         } do
      {:ok, old} = Postgres.claim(branch.id, @config)
      :ok = Postgres.append(old, 1, delta(1), @config)
      {:ok, newer} = Postgres.claim(branch.id, @config)

      assert {:error, %Error{reason: :fenced}} = Postgres.put(%{old | wal: 1}, @config)
      assert stored_seqs(branch) == [1]

      assert Postgres.put(%{newer | wal: 1}, @config) == :ok
      assert stored_seqs(branch) == []
    end

    test "an append for a row that is not stored says so", %{branch: branch} do
      {:ok, held} = Postgres.claim(branch.id, @config)
      :ok = Postgres.delete(branch.id, @config)

      assert {:error, %Error{reason: :storage}} = Postgres.append(held, 1, delta(1), @config)
    end

    test "a branch without an epoch is written unconditionally", %{branch: branch} do
      {:ok, _claimed} = Postgres.claim(branch.id, @config)

      assert branch.epoch == nil
      assert Postgres.append(branch, 1, delta(1), @config) == :ok
      assert Postgres.writes_after(branch, @config) == {:ok, [{1, delta(1)}]}
    end
  end

  describe "appends racing a claim" do
    # The statements must run on connections of their own, which the shared connection of the sandbox does not give.
    setup do
      Sandbox.mode(TestRepo, :auto)
      on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
      branch = durable()
      :ok = Postgres.put(branch, @config)
      on_exit(fn -> Postgres.delete(branch.id, @config) end)
      {:ok, branch: branch}
    end

    test "the next holder reads every delta the old one was told was stored, and none it was refused",
         %{
           branch: branch
         } do
      {:ok, old} = Postgres.claim(branch.id, @config)

      appender =
        Task.async(fn ->
          for seq <- 1..60, do: {seq, Postgres.append(old, seq, delta(seq), @config)}
        end)

      Process.sleep(2)
      {:ok, newer} = Postgres.claim(branch.id, @config)
      results = Task.await(appender)
      {:ok, read} = Postgres.writes_after(newer, @config)

      accepted = for {seq, :ok} <- results, do: seq

      assert Enum.all?(results, fn {_seq, r} ->
               r == :ok or match?({:error, %Error{reason: :fenced}}, r)
             end)

      # An accepted append came before the claim, so the claimer's read has it; a refused one is not in the log.
      assert Enum.map(read, &elem(&1, 0)) == accepted
      assert logged_seqs(branch.id) == accepted
    end
  end

  describe "a durable branch through the supervisor" do
    alias Ecto.Adapters.SQL

    # The action of a branch on a Postgres resource holds a connection in its transaction while the branch process
    # stores the action's delta over another, which a sandbox that shares one connection among the processes cannot
    # give. So this runs on real connections, and everything it writes is deleted at the end.
    setup do
      Sandbox.mode(TestRepo, :auto)
      on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo, durable: true})
      {:ok, branch} = Ramal.branch(Farm)
      on_exit(fn -> Postgres.delete(branch.id, @config) end)
      {:ok, branch: branch}
    end

    defp logged_seqs(id) do
      {:ok, uuid} = Ecto.UUID.dump(id)

      %{rows: rows} =
        SQL.query!(
          TestRepo,
          "SELECT seq FROM ramal_branch_writes WHERE branch_id = $1 ORDER BY seq",
          [uuid]
        )

      List.flatten(rows)
    end

    test "is durable when the supervisor says so", %{branch: branch} do
      assert branch.durable
    end

    test "comes back from a kill with every write of every action that ended", %{branch: branch} do
      Ramal.run!(branch, fn ->
        herd = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.create!(Paddock, %{name: "L99", capacity_head: 10}, authorize?: false)
        Ash.update!(herd, %{head: 6}, authorize?: false)
      end)

      Ramal.run!(branch, fn ->
        herd = Ash.create!(Herd, %{name: "R11", head: 1}, authorize?: false)
        Ash.destroy!(herd, authorize?: false)
      end)

      assert logged_seqs(branch.id) == [1, 2, 3, 4, 5]
      {:ok, before_crash} = Ramal.get(branch.id)
      {:ok, diff} = Ramal.diff(branch)
      assert length(diff) == 2

      crash(branch.id)

      assert {:ok, ^before_crash} = Ramal.get(branch.id)
      assert Ramal.diff(branch) == {:ok, diff}
      # The recovered process stored a snapshot that covers what it applied.
      eventually(fn -> logged_seqs(branch.id) == [] end)
      assert {:ok, %{wal: 5}} = Postgres.fetch(branch.id, @config)
    end

    test "a fork of it survives a kill with what it copied and what it wrote", %{branch: parent} do
      Ramal.run!(parent, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)
      {:ok, fork} = Ramal.fork(parent)
      on_exit(fn -> Postgres.delete(fork.id, @config) end)
      Ramal.run!(fork, fn -> Ash.create!(Herd, %{name: "R11", head: 6}, authorize?: false) end)

      assert logged_seqs(parent.id) == [1]
      assert logged_seqs(fork.id) == [1]
      {:ok, before_crash} = Ramal.get(fork.id)
      assert before_crash.wal == 1

      crash(fork.id)

      assert {:ok, ^before_crash} = Ramal.get(fork.id)
      assert {:ok, [_, _]} = Ramal.diff(fork)
      assert {:ok, [_]} = Ramal.diff(parent)
    end

    test "has the deltas deleted by the snapshot it unloads with", %{branch: branch} do
      Ramal.run!(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)
      assert logged_seqs(branch.id) == [1]

      # Stopping the process stores the branch whole, which covers the delta.
      :ok = GenServer.stop(Ramal.Supervisor.whereis(branch.id))

      assert logged_seqs(branch.id) == []
      assert {:ok, %{wal: 1}} = Postgres.fetch(branch.id, @config)
      assert {:ok, loaded} = Ramal.get(branch.id)
      assert length(loaded.log) == 1
    end

    test "deleting the branch from storage deletes its log", %{branch: branch} do
      Ramal.run!(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)
      assert logged_seqs(branch.id) == [1]

      assert Postgres.delete(branch.id, @config) == :ok

      assert logged_seqs(branch.id) == []
    end
  end

  describe "the owner column" do
    alias Ecto.Adapters.SQL

    defp owner_column(id) do
      {:ok, uuid} = Ecto.UUID.dump(id)

      %{rows: [[owner]]} =
        SQL.query!(TestRepo, "SELECT owner FROM ramal_branches WHERE id = $1", [uuid])

      owner
    end

    test "Postgres fills it from the owner in the state, and it is NULL for an unowned branch" do
      for owner <- ["ana", 7, {:user, 7}, %{"id" => 1}] do
        branch = branch(owner: owner)
        :ok = Postgres.put(branch, @config)

        assert {:ok, json} = Codec.encode_owner(owner)
        assert owner_column(branch.id) == json
      end

      unowned = branch()
      :ok = Postgres.put(unowned, @config)
      assert owner_column(unowned.id) == nil
    end

    test "the column follows the state when the branch is put again" do
      branch = branch(owner: "ana")
      :ok = Postgres.put(branch, @config)
      :ok = Postgres.put(%{branch | owner: "luis"}, @config)

      assert owner_column(branch.id) == "luis"
      assert {:ok, []} = Postgres.list(Farm, [owner: "ana"], @config)
      assert {:ok, [%Branch{owner: "luis"}]} = Postgres.list(Farm, [owner: "luis"], @config)
    end

    test "a row written without the column, as 0.3.0 wrote it, is found by owner" do
      owned = branch(owner: "ana")
      unowned = branch()
      pre_owner = branch()

      for b <- [owned, unowned, pre_owner], do: :ok = Postgres.put(b, @config)

      {:ok, id} = Ecto.UUID.dump(pre_owner.id)

      # The state of a branch stored before owners existed has no "owner" key at all.
      SQL.query!(TestRepo, "UPDATE ramal_branches SET state = state - 'owner' WHERE id = $1", [id])

      assert owner_column(pre_owner.id) == nil
      assert {:ok, [^owned]} = Postgres.list(Farm, [owner: "ana"], @config)

      assert {:ok, listed} = Postgres.list(Farm, [owner: nil], @config)
      assert Enum.sort(Enum.map(listed, & &1.id)) == Enum.sort([unowned.id, pre_owner.id])
    end

    test "the filter does not decode the rows of other owners" do
      mine = branch(owner: "ana")
      theirs = branch(owner: "luis")
      for b <- [mine, theirs], do: :ok = Postgres.put(b, @config)

      # A state that cannot be decoded, with the owner kept so that the column keeps its value.
      {:ok, id} = Ecto.UUID.dump(theirs.id)

      SQL.query!(TestRepo, "UPDATE ramal_branches SET state = $2 WHERE id = $1", [
        id,
        %{"owner" => "luis", "broken" => true}
      ])

      assert Postgres.list(Farm, [owner: "ana"], @config) == {:ok, [mine]}
    end

    test "the index serves a lookup by owner" do
      :ok = Postgres.put(branch(owner: "ana"), @config)

      SQL.query!(TestRepo, "SET LOCAL enable_seqscan = off")

      %{rows: plan} =
        SQL.query!(
          TestRepo,
          "EXPLAIN SELECT id FROM ramal_branches WHERE domain = $1 AND owner = $2::jsonb",
          ["Elixir.Ramal.Test.Farm", "\"ana\""]
        )

      assert plan |> List.flatten() |> Enum.join("\n") =~ "ramal_branches_owner_index"
    end

    test "a table without the column still stores and fetches, and only the owner filter fails" do
      SQL.query!(TestRepo, "ALTER TABLE ramal_branches DROP COLUMN owner")
      branch = branch(owner: "ana")

      assert Postgres.put(branch, @config) == :ok
      assert Postgres.fetch(branch.id, @config) == {:ok, branch}
      assert {:ok, [^branch]} = Postgres.list(Farm, [], @config)

      assert {:error, %Error{reason: :storage, message: message}} =
               Postgres.list(Farm, [owner: "ana"], @config)

      assert message =~ "mix ramal.gen.migration"
    end
  end

  describe "through the supervisor" do
    @describetag supervisor: true

    setup do
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo, idle_timeout: 50})

      {:ok, Seeds.seed!()}
    end

    test "an unloaded branch comes back with the same overlay, log, base and diff", %{
      herds: herds
    } do
      {:ok, branch} = Ramal.branch(Farm, name: "move")

      Ramal.run!(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.destroy!(herds.r9, authorize?: false)
      end)

      {:ok, before_unload} = Ramal.get(branch.id)
      {:ok, diff} = Ramal.diff(branch)
      eventually(fn -> not loaded?(branch.id) end)

      {:ok, after_load} = Ramal.get(branch.id)
      assert after_load == before_unload
      assert Ramal.diff(branch) == {:ok, diff}
    end

    test "a rehydrated branch merges", %{herds: herds} do
      {:ok, branch} = Ramal.branch(Farm)
      Ramal.run!(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      eventually(fn -> not loaded?(branch.id) end)

      assert {:ok, %{replayed: 1}} = Ramal.merge(branch, authorize?: false)
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 31
      assert {:ok, [%{status: :merged}]} = Ramal.list(Farm, status: :merged)
    end

    test "a proposal is stored, unloaded, and approved after rehydration", %{herds: herds} do
      {:ok, branch} = Ramal.branch(Farm)
      Ramal.run!(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      {:ok, proposed} = Ramal.propose(branch, proposed_by: %{id: 1}, reason: "recount")
      eventually(fn -> not loaded?(branch.id) end)

      assert {:ok, [listed]} = Ramal.list(Farm, status: :proposed)
      assert listed == proposed

      assert {:ok, %{branch: approved}} =
               Ramal.approve(branch, decided_by: %{id: 2}, authorize?: false)

      assert approved.proposal.decision.status == :approved
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 31
      assert {:ok, stored} = Ramal.get(branch.id)
      assert stored.status == :merged and stored.proposal == approved.proposal
    end

    test "a rehydrated branch keeps reading its own writes", %{herds: herds} do
      {:ok, branch} = Ramal.branch(Farm)
      Ramal.run!(branch, fn -> Ash.destroy!(herds.r8, authorize?: false) end)
      eventually(fn -> not loaded?(branch.id) end)

      names =
        Ramal.run!(branch, fn -> Herd |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) end)

      assert Enum.sort(names) == ["R7", "R9"]
    end
  end

  describe "across a fresh VM" do
    # The sandbox would roll the rows back before another OS process could see them.
    setup do
      Sandbox.mode(TestRepo, :auto)

      on_exit(fn ->
        Sandbox.mode(TestRepo, :manual)
      end)
    end

    @tag timeout: 120_000
    test "a branch a supervisor persisted on shutdown is loaded identically by a new BEAM" do
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo})
      {:ok, branch} = Ramal.branch(Farm, name: "persisted on shutdown")
      on_exit(fn -> Postgres.delete(branch.id, @config) end)

      Ramal.run!(branch, fn ->
        Ash.create!(Herd, %{name: "R78", head: 8}, authorize?: false)
        Ash.create!(Paddock, %{name: "L99", capacity_head: 10}, authorize?: false)
      end)

      {:ok, in_memory} = Ramal.get(branch.id)
      assert length(in_memory.log) == 2
      stop_supervised!(Ramal.Supervisor)

      assert fetch_in_new_vm(branch.id) == in_memory
    end

    @tag timeout: 120_000
    test "a durable branch's snapshot and write log are loaded identically by a new BEAM" do
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo, durable: true})
      {:ok, branch} = Ramal.branch(Farm, name: "durable")
      on_exit(fn -> Postgres.delete(branch.id, @config) end)

      Ramal.run!(branch, fn -> Ash.create!(Herd, %{name: "R78", head: 8}, authorize?: false) end)

      Ramal.run!(branch, fn ->
        Ash.create!(Paddock, %{name: "L99", capacity_head: 10}, authorize?: false)
      end)

      # The process is still up: storage holds the branch as created and two deltas.
      {:ok, in_memory} = Ramal.get(branch.id)
      assert in_memory.wal == 2

      assert fetch_in_new_vm(branch.id, true) == in_memory
    end

    @tag timeout: 120_000
    test "a branch stored here is loaded identically by a new BEAM that has not loaded the host's modules" do
      herd = struct(Herd, id: Ash.UUID.generate(), name: "R77", head: 7)

      branch =
        branch(
          overlay: %{{Herd, herd.id} => {:created, herd}, {Herd, "gone"} => :deleted},
          base: %{{Herd, "gone"} => %{fingerprint: 1_234_567, snapshot: herd}},
          log: [
            {:create, Herd, :create, %{name: "R77", head: 7}, %{role: :admin},
             [key: herd.id, tenant: nil, nested?: false], DateTime.utc_now()}
          ],
          metadata: %{"note" => "fresh vm", "tags" => ["a", "b"]}
        )

      :ok = Postgres.put(branch, @config)
      on_exit(fn -> Postgres.delete(branch.id, @config) end)

      assert fetch_in_new_vm(branch.id) == branch
    end
  end

  describe "fencing by epoch" do
    setup do
      branch = branch()
      :ok = Postgres.put(branch, @config)
      {:ok, branch: branch}
    end

    test "each claim takes the next epoch and returns the stored branch with it", %{
      branch: branch
    } do
      assert {:ok, %{epoch: 1} = claimed} = Postgres.claim(branch.id, @config)
      assert %{claimed | epoch: nil} == branch
      assert {:ok, %{epoch: 2}} = Postgres.claim(branch.id, @config)
    end

    test "a claim returns what was saved last, so a load cannot start from an older read", %{
      branch: branch
    } do
      {:ok, held} = Postgres.claim(branch.id, @config)
      :ok = Postgres.put(%{held | name: "saved by the holder"}, @config)

      assert {:ok, %{name: "saved by the holder", epoch: 2}} = Postgres.claim(branch.id, @config)
    end

    test "the holder of the current epoch writes, and fetch leaves the epoch out", %{
      branch: branch
    } do
      {:ok, held} = Postgres.claim(branch.id, @config)

      assert Postgres.put(%{held | name: "renamed"}, @config) == :ok
      assert {:ok, %{name: "renamed", epoch: nil}} = Postgres.fetch(branch.id, @config)
    end

    test "a write by the holder of an older epoch is refused and changes nothing", %{
      branch: branch
    } do
      {:ok, old} = Postgres.claim(branch.id, @config)
      {:ok, newer} = Postgres.claim(branch.id, @config)
      :ok = Postgres.put(%{newer | name: "newer"}, @config)

      assert {:error, %Error{reason: :fenced, details: %{epoch: 1}}} =
               Postgres.put(%{old | name: "older"}, @config)

      assert {:ok, %{name: "newer"}} = Postgres.fetch(branch.id, @config)
    end

    test "a write to a row that was deleted is refused and does not bring it back", %{
      branch: branch
    } do
      {:ok, held} = Postgres.claim(branch.id, @config)
      :ok = Postgres.delete(branch.id, @config)

      assert {:error, %Error{reason: :fenced}} = Postgres.put(held, @config)
      assert {:error, %Error{reason: :not_found}} = Postgres.fetch(branch.id, @config)
    end

    test "a merged row stays merged under a write of the current epoch, as without an epoch", %{
      branch: branch
    } do
      {:ok, held} = Postgres.claim(branch.id, @config)
      :ok = Postgres.put(%{branch | status: :merged}, @config)

      assert Postgres.put(%{held | name: "open again"}, @config) == :ok
      assert {:ok, %{status: :merged, name: "stored"}} = Postgres.fetch(branch.id, @config)
    end

    test "a write with no epoch is not fenced and leaves the epoch as it is", %{branch: branch} do
      {:ok, _held} = Postgres.claim(branch.id, @config)

      assert Postgres.put(%{branch | name: "plain"}, @config) == :ok
      assert {:ok, %{epoch: 2}} = Postgres.claim(branch.id, @config)
    end

    test "a merge mark by the holder of an older epoch is refused and the row stays open", %{
      branch: branch
    } do
      {:ok, old} = Postgres.claim(branch.id, @config)
      {:ok, current} = Postgres.claim(branch.id, @config)

      assert {:error, %Error{reason: :fenced}} = Postgres.mark_merged(old, @config)
      assert {:ok, %{status: :open}} = Postgres.fetch(branch.id, @config)

      assert Postgres.mark_merged(current, @config) == :ok
      assert {:ok, %{status: :merged}} = Postgres.fetch(branch.id, @config)

      assert {:error, %Error{reason: :not_open, details: %{status: :merged}}} =
               Postgres.mark_merged(current, @config)
    end

    test "a claim of a branch whose stored epoch is NULL still takes an integer epoch", %{
      branch: branch
    } do
      {:ok, uuid} = Ecto.UUID.dump(branch.id)

      # The migration makes the column NOT NULL, so a NULL epoch needs a hand-edited table. Claimed as nil, it would
      # turn the fencing off for the branch. The ALTER is rolled back with the test's transaction.
      SQL.query!(TestRepo, "ALTER TABLE ramal_branches ALTER COLUMN epoch DROP NOT NULL", [])
      SQL.query!(TestRepo, "UPDATE ramal_branches SET epoch = NULL WHERE id = $1", [uuid])

      assert {:ok, %{epoch: 1}} = Postgres.claim(branch.id, @config)
      assert {:ok, %{epoch: 2}} = Postgres.claim(branch.id, @config)
    end

    test "claiming an unknown id, or one that is not a UUID, is :not_found" do
      assert {:error, %Error{reason: :not_found}} = Postgres.claim(Ash.UUID.generate(), @config)
      assert {:error, %Error{reason: :not_found}} = Postgres.claim("nope", @config)
    end
  end

  # Starts another BEAM on the same compiled code, so nothing is loaded in it but what the fetch itself loads. With
  # `log: true` it also applies the write log, as a branch process loads a durable branch.
  defp fetch_in_new_vm(id, log \\ false) do
    script = """
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Ramal.TestRepo.start_link()
    config = [repo: Ramal.TestRepo]
    {:ok, branch} = Ramal.Storage.Postgres.fetch("#{id}", config)

    branch =
      if #{log} do
        {:ok, deltas} = Ramal.Storage.Postgres.writes_after(branch, config)
        Enum.reduce(deltas, branch, fn {seq, delta}, acc -> Ramal.Branch.apply_delta(acc, seq, delta) end)
      else
        branch
      end

    IO.puts("RAMAL_BRANCH:" <> Base.encode64(:erlang.term_to_binary(branch)))
    """

    {output, status} =
      System.cmd(
        System.find_executable("mix"),
        ["run", "--no-start", "--no-compile", "-e", script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    [encoded] = Regex.run(~r/RAMAL_BRANCH:(\S+)/, output, capture: :all_but_first)
    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end
end
