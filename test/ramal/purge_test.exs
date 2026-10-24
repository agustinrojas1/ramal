defmodule Ramal.PurgeTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [capture_branch_events: 0, loaded?: 1]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ramal.Error
  alias Ramal.Storage.{ETS, Postgres}
  alias Ramal.Test.{Capture, DurableStorage, Farm}
  alias Ramal.Test.Capture.Silent
  alias Ramal.Test.Farm.Herd
  alias Ramal.TestRepo

  @branches 1_000

  setup context do
    unless context[:own_supervisor], do: start_supervised!(Ramal.Supervisor)
    :ok
  end

  defp stored(domain \\ Farm) do
    {:ok, branches} = Ramal.list(domain)
    branches
  end

  defp propose(branch), do: Ramal.propose(branch, proposed_by: %{id: 1}, reason: "r")

  describe "discard/2 with purge: true" do
    test "removes the record from storage, list/2 and get/1" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Farm)

      assert Ramal.discard(branch, purge: true) == :ok

      assert {:error, %Error{reason: :not_found}} = Ramal.get(branch.id)
      assert {:error, %Error{reason: :not_found}} = ETS.fetch(branch.id, [])
      assert stored() == []
      refute loaded?(branch.id)
      assert_received {:telemetry, [:ramal, :branch, :discard], %{branch_id: id}}
      assert id == branch.id
      assert_received {:telemetry, [:ramal, :branch, :delete], %{branch_id: ^id}}
    end

    test "without the option the discarded record is kept, as before" do
      {:ok, branch} = Ramal.branch(Farm)

      assert Ramal.discard(branch, purge: false) == :ok
      assert [%{id: id, status: :discarded}] = stored()
      assert id == branch.id
    end

    test "purges a proposed branch too, and refuses a merged one without deleting it" do
      {:ok, proposed} = Ramal.branch(Farm)
      {:ok, _proposed} = propose(proposed)
      assert Ramal.discard(proposed, purge: true) == :ok

      {:ok, merged} = Ramal.branch(Farm)
      assert {:ok, _result} = Ramal.merge(merged, authorize?: false)
      assert {:error, %Error{reason: :not_open}} = Ramal.discard(merged, purge: true)
      assert [%{id: id, status: :merged}] = stored()
      assert id == merged.id
    end

    test "discarding a branch that is gone is an error and purges nothing" do
      {:ok, branch} = Ramal.branch(Farm)
      :ok = Ramal.discard(branch, purge: true)

      assert {:error, %Error{reason: :not_found}} = Ramal.discard(branch.id, purge: true)
    end
  end

  describe "delete/1" do
    test "refuses an open branch and a proposed one, and keeps them" do
      {:ok, open} = Ramal.branch(Farm)
      {:ok, proposed} = Ramal.branch(Farm)
      {:ok, _proposed} = propose(proposed)

      assert {:error, %Error{reason: :not_terminal, details: %{status: :open}}} =
               Ramal.delete(open)

      assert {:error, %Error{reason: :not_terminal, details: %{status: :proposed}} = error} =
               Ramal.delete(proposed.id)

      assert Exception.message(error) =~ "purge: true"
      assert length(stored()) == 2
      assert {:ok, %{status: :open}} = Ramal.get(open.id)
    end

    test "removes a discarded, a merged and a rejected branch" do
      {:ok, discarded} = Ramal.branch(Farm)
      :ok = Ramal.discard(discarded)

      {:ok, merged} = Ramal.branch(Farm)
      {:ok, _result} = Ramal.merge(merged, authorize?: false)

      {:ok, rejected} = Ramal.branch(Farm)
      {:ok, _proposed} = propose(rejected)
      {:ok, _rejected} = Ramal.reject(rejected, decided_by: %{id: 2}, reason: "no")

      assert length(stored()) == 3

      for branch <- [discarded, merged, rejected] do
        assert Ramal.delete(branch) == :ok
        assert {:error, %Error{reason: :not_found}} = Ramal.get(branch.id)
      end

      assert stored() == []
    end

    test "a branch that is not in storage is not found" do
      assert {:error, %Error{reason: :not_found}} = Ramal.delete(Ecto.UUID.generate())
    end

    test "leaves other branches alone" do
      {:ok, keep} = Ramal.branch(Farm)
      {:ok, drop} = Ramal.branch(Farm)

      assert Ramal.discard(drop, purge: true) == :ok
      assert [%{id: id}] = stored()
      assert id == keep.id
    end
  end

  describe "a branch used as scratch space" do
    test "1,000 opened and purged leave nothing in ETS storage" do
      for _ <- 1..@branches do
        {:ok, branch} = Ramal.branch(Farm)
        :ok = Ramal.discard(branch, purge: true)
      end

      assert stored() == []
      assert {:ok, []} = ETS.list(Farm, [], [])
    end
  end

  describe "a durable branch" do
    @describetag own_supervisor: true

    setup do
      start_supervised!({Ramal.Supervisor, storage: DurableStorage})
      :ok
    end

    test "loses its write log with its record" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      Ramal.run!(branch, fn -> Ash.create!(Silent, %{text: "x"}, authorize?: false) end)

      assert {:ok, [_delta | _]} = ETS.writes_after(branch, [])
      assert Ramal.discard(branch, purge: true) == :ok
      assert ETS.writes_after(branch, []) == {:ok, []}
      assert stored(Capture) == []
    end
  end

  describe "Postgres storage" do
    @describetag own_supervisor: true

    setup do
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo})
      :ok
    end

    defp stored_rows do
      %{rows: [[count]]} = SQL.query!(TestRepo, "SELECT count(*) FROM ramal_branches", [])
      count
    end

    test "1,000 opened and purged leave no row" do
      for _ <- 1..@branches do
        {:ok, branch} = Ramal.branch(Farm)
        :ok = Ramal.discard(branch, purge: true)
      end

      assert stored() == []
      assert stored_rows() == 0
    end

    test "delete/1 refuses an open branch and removes a discarded one" do
      {:ok, branch} = Ramal.branch(Farm)

      assert {:error, %Error{reason: :not_terminal}} = Ramal.delete(branch)
      assert stored_rows() == 1

      :ok = Ramal.discard(branch)
      assert [%{status: :discarded}] = stored()
      assert Ramal.delete(branch) == :ok
      assert stored_rows() == 0
    end
  end

  describe "a durable branch on Postgres storage" do
    @describetag own_supervisor: true

    # The action holds a connection in its transaction while the branch process stores the delta over another, which a
    # sandbox sharing one connection cannot give (see storage_postgres_test.exs), so this runs on real connections.
    setup do
      Sandbox.mode(TestRepo, :auto)
      on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
      start_supervised!({Ramal.Supervisor, storage: Postgres, repo: TestRepo, durable: true})
      :ok
    end

    test "loses its write log rows with its record" do
      {:ok, branch} = Ramal.branch(Farm)
      on_exit(fn -> Postgres.delete(branch.id, repo: TestRepo) end)
      Ramal.run!(branch, fn -> Ash.create!(Herd, %{name: "P1", head: 1}, authorize?: false) end)

      {:ok, uuid} = Ecto.UUID.dump(branch.id)
      count = "SELECT count(*) FROM ramal_branch_writes WHERE branch_id = $1"
      assert %{rows: [[n]]} = SQL.query!(TestRepo, count, [uuid])
      assert n > 0

      assert Ramal.discard(branch, purge: true) == :ok
      assert %{rows: [[0]]} = SQL.query!(TestRepo, count, [uuid])
    end
  end
end
