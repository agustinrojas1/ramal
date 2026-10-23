defmodule Ramal.OwnerTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.{Branch, Storage.Codec}

  # A storage written before owners existed: it takes the filters and ignores `:owner`.
  defmodule IgnoresOwner do
    @moduledoc false
    @behaviour Ramal.Storage

    defdelegate put(branch, config), to: Ramal.Storage.ETS
    defdelegate fetch(id, config), to: Ramal.Storage.ETS
    defdelegate delete(id, config), to: Ramal.Storage.ETS

    def list(domain, filters, config),
      do: Ramal.Storage.ETS.list(domain, Keyword.delete(filters, :owner), config)
  end

  defp ids(branches), do: branches |> Enum.map(& &1.id) |> Enum.sort()

  describe "the owner of a branch" do
    test "is nil unless given" do
      assert Branch.new(Farm).owner == nil
    end

    test "a fork keeps the parent's owner unless it is given another" do
      parent = Branch.new(Farm, owner: "ana")

      assert Branch.fork(parent).owner == "ana"
      assert Branch.fork(parent, owner: "luis").owner == "luis"
      assert Branch.fork(parent, owner: nil).owner == nil
    end

    test "is not printed by inspect" do
      refute inspect(Branch.new(Farm, owner: %{email: "ana@example.com"})) =~ "ana@example.com"
    end

    test "survives the codec as the term it is" do
      for owner <- [nil, "ana", 7, :admin, {:user, 7}, %{"id" => 1}, %{id: 1}] do
        branch = Branch.new(Farm, owner: owner)
        {:ok, state} = Codec.encode_state(branch)
        columns = %{id: branch.id, domain: "Elixir.Ramal.Test.Farm", name: nil, status: "open"}

        assert {:ok, %Branch{owner: ^owner}} = Codec.decode_state(columns, state)
      end
    end

    test "a state stored before owners existed loads as unowned" do
      branch = Branch.new(Farm)
      {:ok, state} = Codec.encode_state(branch)
      columns = %{id: branch.id, domain: "Elixir.Ramal.Test.Farm", name: nil, status: "open"}

      assert {:ok, %Branch{owner: nil}} = Codec.decode_state(columns, Map.delete(state, "owner"))
    end

    test "a value that cannot be stored is an error from the codec" do
      assert {:error, %Ramal.Error{reason: :storage}} = Codec.encode_owner(self())
    end
  end

  for {label, storage_opts} <- [
        ets: [storage: Ramal.Storage.ETS],
        postgres: [storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo],
        "a storage that ignores the owner filter": [storage: IgnoresOwner]
      ] do
    describe "Ramal.list/2 with #{label}" do
      setup do
        start_supervised!({Ramal.Supervisor, unquote(storage_opts)})
        {:ok, ana} = Ramal.branch(Farm, name: "ana's", owner: "ana")
        {:ok, luis} = Ramal.branch(Farm, name: "luis'", owner: "luis")
        {:ok, nobody} = Ramal.branch(Farm, name: "nobody's")
        {:ok, tuple} = Ramal.branch(Farm, name: "tuple", owner: {:user, 7})
        %{ana: ana, luis: luis, nobody: nobody, tuple: tuple}
      end

      test "without :owner lists every branch, as before", ctx do
        assert {:ok, all} = Ramal.list(Farm)
        assert ids(all) == ids([ctx.ana, ctx.luis, ctx.nobody, ctx.tuple])
      end

      test "with :owner lists that owner's branches only", ctx do
        assert {:ok, [only]} = Ramal.list(Farm, owner: "ana")
        assert only.id == ctx.ana.id

        assert {:ok, [only]} = Ramal.list(Farm, owner: {:user, 7})
        assert only.id == ctx.tuple.id

        assert {:ok, []} = Ramal.list(Farm, owner: "someone else")
      end

      test "owner: nil lists the branches that have none", ctx do
        assert {:ok, [only]} = Ramal.list(Farm, owner: nil)
        assert only.id == ctx.nobody.id
      end

      test "an owner never matches by prefix or by another type", _ctx do
        assert {:ok, []} = Ramal.list(Farm, owner: "an")
        assert {:ok, []} = Ramal.list(Farm, owner: :ana)
        assert {:ok, []} = Ramal.list(Farm, owner: 7)
      end

      test "combines with :status", ctx do
        :ok = Ramal.discard(ctx.ana)
        {:ok, again} = Ramal.branch(Farm, owner: "ana")

        assert {:ok, [open]} = Ramal.list(Farm, owner: "ana", status: :open)
        assert open.id == again.id
        assert {:ok, [discarded]} = Ramal.list(Farm, owner: "ana", status: :discarded)
        assert discarded.id == ctx.ana.id
        assert {:ok, []} = Ramal.list(Farm, owner: "luis", status: :discarded)
      end

      test "a fork is listed under the owner it was given", ctx do
        {:ok, inherited} = Ramal.fork(ctx.ana)
        {:ok, given} = Ramal.fork(ctx.ana, owner: "luis")

        assert {:ok, ana} = Ramal.list(Farm, owner: "ana")
        assert ids(ana) == ids([ctx.ana, inherited])

        assert {:ok, luis} = Ramal.list(Farm, owner: "luis")
        assert ids(luis) == ids([ctx.luis, given])
      end

      test "the owner of a branch read back is the one it was created with", ctx do
        assert {:ok, %Branch{owner: "ana"}} = Ramal.get(ctx.ana.id)
        assert {:ok, %Branch{owner: nil}} = Ramal.get(ctx.nobody.id)
      end
    end
  end

  describe "Ramal.Storage.Postgres" do
    test "a branch stored without an owner key is found by owner: nil" do
      start_supervised!({Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo})
      {:ok, branch} = Ramal.branch(Farm)

      Ramal.TestRepo.query!("UPDATE ramal_branches SET state = state - 'owner' WHERE id = $1", [
        Ecto.UUID.dump!(branch.id)
      ])

      assert {:ok, [listed]} = Ramal.list(Farm, owner: nil)
      assert listed.id == branch.id
    end

    test "an owner that cannot be stored is an error, not a crash" do
      start_supervised!({Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo})

      assert {:error, %Ramal.Error{reason: :storage}} = Ramal.list(Farm, owner: self())
    end
  end
end
