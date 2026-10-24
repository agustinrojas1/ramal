defmodule Ramal.UpsertTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL
  alias Ramal.Error
  alias Ramal.Merge.Result

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  defp upsert(attrs, action),
    do: Ash.create(Paddock, attrs, action: action, authorize?: false)

  defp upsert!(attrs, action \\ :upsert),
    do: Ash.create!(Paddock, attrs, action: action, authorize?: false)

  defp diff(branch) do
    {:ok, changes} = Ramal.diff(branch)
    changes
  end

  defp base(paddock), do: Ash.get!(Paddock, paddock.id, authorize?: false)
  defp base_count, do: Paddock |> Ash.read!(authorize?: false) |> length()

  describe "an upsert of a row the base holds" do
    test "updates that row in the branch's view and leaves the database alone", %{
      branch: branch,
      paddocks: paddocks
    } do
      returned =
        inside(branch, fn ->
          upsert!(%{name: "L07", hectares: 41.0, capacity_head: 120})
        end)

      assert returned.id == paddocks.l07.id
      assert base(paddocks.l07).capacity_head == 100
      assert base_count() == 2

      [change] = diff(branch)
      assert %{kind: :updated, key: key} = change
      assert key == paddocks.l07.id
      assert change.changes.capacity_head == {100, 120}

      seen = inside(branch, fn -> Ash.read!(Paddock, authorize?: false) end)
      assert length(seen) == 2
      assert Enum.find(seen, &(&1.name == "L07")).capacity_head == 120
    end

    test "is replayed as an upsert by the merge, which updates that row", %{
      branch: branch,
      paddocks: paddocks
    } do
      inside(branch, fn -> upsert!(%{name: "L07", hectares: 41.0, capacity_head: 120}) end)

      assert {:ok, %Result{replayed: 1, records: records}} =
               Ramal.merge(branch, authorize?: false)

      assert {:updated, %{id: id}} = records[{Paddock, paddocks.l07.id}]
      assert id == paddocks.l07.id
      assert base(paddocks.l07).capacity_head == 120
      assert base_count() == 2
    end

    test "is stale when the base row changed under the branch", %{
      branch: branch,
      paddocks: paddocks
    } do
      inside(branch, fn -> upsert!(%{name: "L07", capacity_head: 120}) end)
      Ash.update!(paddocks.l07, %{capacity_head: 7}, authorize?: false)

      assert {:error, %Error{reason: :stale, details: %{rows: [row]}}} =
               Ramal.merge(branch, authorize?: false)

      assert row == %{resource: Paddock, key: paddocks.l07.id, reason: :changed}
      assert base(paddocks.l07).capacity_head == 7
    end

    test "a second upsert in the branch updates the same row again", %{
      branch: branch,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        upsert!(%{name: "L07", capacity_head: 110})
        upsert!(%{name: "L07", capacity_head: 130})
      end)

      assert [%{kind: :updated, changes: %{capacity_head: {100, 130}}}] = diff(branch)
      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      assert base(paddocks.l07).capacity_head == 130
      assert base_count() == 2
    end
  end

  describe "an upsert of a row the base does not hold" do
    test "creates it, in the branch only", %{branch: branch} do
      created = inside(branch, fn -> upsert!(%{name: "L99", capacity_head: 5}) end)

      assert base_count() == 2
      assert [%{kind: :created, key: key}] = diff(branch)
      assert key == created.id
    end

    test "keeps the key the branch gave it when merged", %{branch: branch} do
      created = inside(branch, fn -> upsert!(%{name: "L99", capacity_head: 5}) end)

      assert {:ok, %Result{records: records}} = Ramal.merge(branch, authorize?: false)
      assert {:created, %{id: id}} = records[{Paddock, created.id}]
      assert id == created.id
      assert base_count() == 3
    end

    test "a row the branch created stays created when it is upserted again", %{branch: branch} do
      {first, second} =
        inside(branch, fn ->
          first = upsert!(%{name: "L99", capacity_head: 5})
          {first, upsert!(%{name: "L99", capacity_head: 9})}
        end)

      assert second.id == first.id
      assert [%{kind: :created, key: key, changes: %{capacity_head: {nil, 9}}}] = diff(branch)
      assert key == first.id

      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      assert base_count() == 3
      assert Ash.get!(Paddock, first.id, authorize?: false).capacity_head == 9
    end

    test "a row created by a plain create is found by a later upsert", %{branch: branch} do
      inside(branch, fn ->
        created = Ash.create!(Paddock, %{name: "L99", capacity_head: 5}, authorize?: false)
        assert upsert!(%{name: "L99", capacity_head: 6}).id == created.id
      end)

      assert [%{kind: :created, changes: %{capacity_head: {nil, 6}}}] = diff(branch)
      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      assert base_count() == 3
    end
  end

  describe "later writes of the row an upsert changed" do
    test "an update after the upsert merges onto the upserted row", %{
      branch: branch,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        upsert!(%{name: "L07", hectares: 41.0, capacity_head: 120})

        Ash.update!(Ash.get!(Paddock, paddocks.l07.id, authorize?: false), %{hectares: 42.0},
          authorize?: false
        )
      end)

      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      merged = base(paddocks.l07)
      assert merged.capacity_head == 120
      assert merged.hectares == 42.0
    end

    test "a destroy after the upsert removes the row at the merge", %{branch: branch} do
      empty = Ash.create!(Paddock, %{name: "L50", capacity_head: 3}, authorize?: false)

      inside(branch, fn ->
        upserted = upsert!(%{name: "L50", capacity_head: 120})
        Ash.destroy!(upserted, authorize?: false)
      end)

      assert [%{kind: :deleted}] = diff(branch)
      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      assert Ash.get(Paddock, empty.id, authorize?: false, not_found_error?: false) == {:ok, nil}
    end
  end

  describe "a row that appears in the base after the branch looked" do
    test "is updated by the merge without taking the branch's key", %{branch: branch} do
      created = inside(branch, fn -> upsert!(%{name: "L99", hectares: 2.0, capacity_head: 5}) end)

      appeared =
        Ash.create!(Paddock, %{name: "L99", hectares: 7.0, capacity_head: 1}, authorize?: false)

      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      assert base_count() == 3
      merged = base(appeared)
      assert merged.id == appeared.id
      assert merged.id != created.id
      assert merged.capacity_head == 5
    end
  end

  describe "the log" do
    test "records the identity, the fields and whether the row was found", %{branch: branch} do
      inside(branch, fn ->
        upsert!(%{name: "L07", capacity_head: 120})
        upsert!(%{name: "L99", capacity_head: 5})
      end)

      {:ok, %{log: log}} = Ramal.get(branch.id)

      [{:create, Paddock, :upsert, _, _, found, _}, {:create, Paddock, :upsert, _, _, created, _}] =
        Enum.reverse(log)

      assert {:unique_name, fields, true} = found[:upsert]
      assert fields == [:capacity_head]
      assert {:unique_name, _fields, false} = created[:upsert]
    end
  end

  describe "upsert_fields" do
    test "limit what an existing row takes from the input", %{branch: branch, paddocks: paddocks} do
      inside(branch, fn ->
        upsert!(%{name: "L07", hectares: 99.0, capacity_head: 120}, :upsert_capacity)
      end)

      assert [%{changes: changes}] = diff(branch)
      assert Map.keys(changes) |> Enum.sort() == [:capacity_head, :updated_at]
      assert changes.capacity_head == {100, 120}

      assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
      merged = base(paddocks.l07)
      assert merged.capacity_head == 120
      assert merged.hectares == 40.0
    end

    test "do not limit the attributes of a new row", %{branch: branch} do
      created =
        inside(branch, fn ->
          upsert!(%{name: "L99", hectares: 3.0, capacity_head: 5}, :upsert_capacity)
        end)

      assert created.hectares == 3.0
    end

    test "default to the attributes the call set, so one it left out keeps the row's value", %{
      branch: branch,
      paddocks: paddocks
    } do
      inside(branch, fn -> upsert!(%{name: "L07", capacity_head: 120}) end)

      assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
      merged = base(paddocks.l07)
      assert merged.capacity_head == 120
      assert merged.hectares == 40.0
    end
  end

  describe "an upsert_condition" do
    test "is refused with a message that says why", %{branch: branch} do
      assert {:error, error} =
               inside(branch, fn ->
                 upsert(%{name: "L07", capacity_head: 120}, :upsert_if_larger)
               end)

      assert %Error{reason: :upsert_unsupported} = Error.find(error)
      assert Exception.message(Error.find(error)) =~ "upsert_condition"
      assert diff(branch) == []
    end
  end

  # What docs/limits.md says about "insert if missing, otherwise leave it alone".
  describe "insert if missing, otherwise leave it alone" do
    defp ctid(paddock) do
      %{rows: [[ctid]]} =
        SQL.query!(TestRepo, "SELECT ctid::text FROM paddocks WHERE id = $1", [
          Ecto.UUID.dump!(paddock.id)
        ])

      ctid
    end

    test "upsert_fields [] still rewrites the row in AshPostgres, which is why a branch cannot skip it",
         %{paddocks: paddocks} do
      before_ctid = ctid(paddocks.l07)

      returned = upsert!(%{name: "L07", capacity_head: 999}, :upsert_nothing)

      assert returned.id == paddocks.l07.id
      assert base(paddocks.l07).capacity_head == 100
      assert ctid(paddocks.l07) != before_ctid
    end

    test "upsert_fields [] in a branch returns the existing row and changes nothing", %{
      branch: branch,
      paddocks: paddocks
    } do
      returned =
        inside(branch, fn -> upsert!(%{name: "L07", capacity_head: 999}, :upsert_nothing) end)

      assert returned.id == paddocks.l07.id
      assert returned.capacity_head == 100

      # No attribute of the input is taken, but the update timestamp is still touched and replayed.
      assert [%{kind: :updated, changes: changes}] = diff(branch)
      assert Map.keys(changes) == [:updated_at]
      assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
      assert base(paddocks.l07).capacity_head == 100
    end

    test "upsert_fields [] in a branch creates the row when it is missing", %{branch: branch} do
      created =
        inside(branch, fn -> upsert!(%{name: "L99", capacity_head: 5}, :upsert_nothing) end)

      assert created.capacity_head == 5
      assert [%{kind: :created}] = diff(branch)
      assert base_count() == 2
    end

    test "a condition that is never true is refused in a branch, with :upsert_unsupported", %{
      branch: branch
    } do
      assert {:error, error} =
               inside(branch, fn -> upsert(%{name: "L07", capacity_head: 999}, :upsert_never) end)

      assert %Error{reason: :upsert_unsupported} = Error.find(error)
      assert diff(branch) == []
    end

    test "a read in the branch first, then a plain create, leaves an existing row alone", %{
      branch: branch,
      paddocks: paddocks
    } do
      insert_if_missing = fn name ->
        case Paddock |> Ash.Query.filter(name == ^name) |> Ash.read_one!(authorize?: false) do
          nil -> Ash.create!(Paddock, %{name: name, capacity_head: 5}, authorize?: false)
          existing -> existing
        end
      end

      inside(branch, fn ->
        assert insert_if_missing.("L07").id == paddocks.l07.id
        created = insert_if_missing.("L99")
        assert insert_if_missing.("L99").id == created.id
      end)

      assert [%{kind: :created}] = diff(branch)
      assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
      assert base_count() == 3
      assert base(paddocks.l07).capacity_head == 100
    end
  end

  describe "outside a branch" do
    test "an upsert action is transparent" do
      paddock = upsert!(%{name: "L07", capacity_head: 101})
      assert paddock.capacity_head == 101
      assert base_count() == 2
    end
  end
end
