defmodule Ramal.Storage.PostgresTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [eventually: 1, loaded?: 1]

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

  # Starts another BEAM on the same compiled code, so nothing is loaded in it but what the fetch itself loads.
  defp fetch_in_new_vm(id) do
    script = """
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Ramal.TestRepo.start_link()
    {:ok, branch} = Ramal.Storage.Postgres.fetch("#{id}", repo: Ramal.TestRepo)
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
