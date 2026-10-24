defmodule Ramal.CustomTypesTest do
  # Custom Ash types (issue 210): a NewType over :string that keeps "" and surrounding spaces, a JSON type with nested
  # lists of maps, and a struct whose database, caller and embedded forms all differ (the shape of a PostGIS geometry).
  # Whatever a branch holds goes through Ash.Type.dump_to_embedded/3 and cast_from_embedded/3 on its way to storage and
  # back, so a type whose embedded form does not round-trip would make a branch read differently from the database with
  # no error. Every step below must give the value the database gives for the same input, and docs/limits.md says what a
  # custom type has to satisfy for that to hold. Ramal.Supervisor is one per node and named, so these tests cannot run
  # concurrently.
  use Ramal.DataCase, async: false
  use ExUnitProperties

  import Ramal.BranchCase, only: [crash: 1, eventually: 1, loaded?: 1]

  alias Ramal.{Error, Resource}
  alias Ramal.Merge.Result
  alias Ramal.Storage.{Codec, ETS, Postgres}
  alias Ramal.Test.Customs
  alias Ramal.Test.Customs.{Entry, Point}

  @attrs [:label, :payload, :point]
  @max_runs 12

  # Every backend a branch can be reloaded from: ETS keeps the terms, Postgres goes through the JSON codec, and a
  # durable branch whose process is killed is rebuilt from its last save and the write log.
  @backends [
    ets: {[idle_timeout: 100], []},
    postgres: {[storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo, idle_timeout: 100], []},
    durable: {[], [durable: true]}
  ]

  defp key_gen, do: string([?a..?c, ?$, ?_], min_length: 1, max_length: 3)

  defp scalar_gen,
    do:
      one_of([
        constant(nil),
        boolean(),
        integer(-1000..1000),
        string(:alphanumeric, max_length: 5),
        member_of(["", " ", "$m", "$a"])
      ])

  defp label_gen,
    do:
      one_of([
        constant(nil),
        member_of(["", " ", "  padded  ", "\n", "a b", "Zoë"]),
        string(:printable, max_length: 12)
      ])

  # Nested lists of maps, with keys that look like the codec's own markers ("$a", "$m"), empty lists and empty maps.
  defp payload_gen do
    row = map_of(key_gen(), scalar_gen(), max_length: 3)

    one_of([
      constant(nil),
      constant(%{}),
      fixed_map(%{
        "items" => list_of(row, max_length: 3),
        "tags" => list_of(scalar_gen(), max_length: 3)
      }),
      map_of(
        key_gen(),
        one_of([
          scalar_gen(),
          list_of(row, max_length: 3),
          list_of(list_of(row, max_length: 2), max_length: 2)
        ]),
        max_length: 3
      )
    ])
  end

  defp point_gen do
    coordinate = fn bound -> float(min: -bound, max: bound) end

    one_of([
      constant(nil),
      map({coordinate.(90.0), coordinate.(180.0)}, fn {lat, lon} -> [lat, lon] end),
      map({coordinate.(90.0), coordinate.(180.0)}, fn {lat, lon} ->
        %{"lat" => lat, "lon" => lon}
      end),
      map({integer(-90..90), integer(-180..180)}, fn {lat, lon} -> %{lat: lat, lon: lon} end)
    ])
  end

  defp attrs_gen,
    do: fixed_map(%{label: label_gen(), payload: payload_gen(), point: point_gen()})

  defp db(entry), do: Map.take(entry, @attrs)

  defp create!(attrs), do: Ash.create!(Entry, attrs, authorize?: false)
  defp get!(id), do: Ash.get!(Entry, id, authorize?: false)
  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  defp diff!(branch) do
    assert {:ok, changes} = Ramal.diff(branch)
    changes
  end

  # What the database returns for these attributes on a row nothing but the database touched.
  defp stored(attrs), do: attrs |> create!() |> Map.fetch!(:id) |> get!() |> db()

  defp same!(left, right), do: assert(left === right)

  # The attribute differences `Ramal.diff/1` should report for a row that went from `before` to `after_values`.
  defp expected_changes(before, after_values) do
    for attr <- @attrs, Map.fetch!(before, attr) !== Map.fetch!(after_values, attr), into: %{} do
      {attr, {Map.fetch!(before, attr), Map.fetch!(after_values, attr)}}
    end
  end

  defp reload(:durable, id), do: crash(id)
  defp reload(_backend, id), do: eventually(fn -> not loaded?(id) end)

  for {backend, {supervisor, branch_opts}} <- @backends do
    describe "a branch on the #{backend} backend" do
      setup do
        start_supervised!({Ramal.Supervisor, unquote(supervisor)})
        :ok
      end

      property "create, update, read, diff, fork, reload and merge give the database's values" do
        check all(
                first <- attrs_gen(),
                second <- attrs_gen(),
                other <- attrs_gen(),
                max_runs: @max_runs
              ) do
          # A merged branch is closed, so each run has its own.
          {:ok, branch} = Ramal.branch(Customs, unquote(branch_opts))
          seeded = first |> create!() |> Map.fetch!(:id)
          untouched = other |> create!() |> Map.fetch!(:id)
          untouched_values = db(get!(untouched))
          before = db(get!(seeded))

          # The reference: the same two steps run against the database alone, on rows of their own.
          created_ref = stored(second)
          updated_ref = first |> create!() |> Ash.update!(second, authorize?: false) |> db()

          {created, updated} =
            inside(branch, fn ->
              created = create!(second)
              updated = Ash.update!(get!(seeded), second, authorize?: false)
              # A read of the whole table fingerprints the rows nobody touched.
              assert Enum.any?(Ash.read!(Entry, authorize?: false), &(&1.id == untouched))

              same!(db(created), created_ref)
              same!(db(updated), updated_ref)
              same!(db(get!(created.id)), created_ref)
              same!(db(get!(updated.id)), updated_ref)
              {created, updated}
            end)

          assert updated.id == seeded

          # Nothing reached the database, which still holds the first values.
          same!(db(get!(seeded)), before)
          assert Ash.get(Entry, created.id, authorize?: false) |> elem(0) == :error

          changes = diff!(branch)
          created_change = Enum.find(changes, &(&1.key == created.id))
          assert created_change.kind == :created

          for attr <- @attrs do
            same!(
              elem(Map.get(created_change.changes, attr, {nil, nil}), 1),
              Map.fetch!(created_ref, attr)
            )
          end

          updated_change = Enum.find(changes, &(&1.key == seeded))
          expected = expected_changes(before, updated_ref)

          if expected == %{} do
            assert updated_change == nil
          else
            same!(Map.take(updated_change.changes, @attrs), expected)
          end

          # A fork starts from what the branch holds and reads and diffs the same.
          {:ok, fork} = Ramal.fork(branch)
          assert diff!(fork) === changes
          same!(inside(fork, fn -> db(get!(created.id)) end), created_ref)
          same!(inside(fork, fn -> db(get!(seeded)) end), updated_ref)

          {:ok, state} = Ramal.get(branch.id)
          assert Map.has_key?(state.base, {Entry, untouched})

          # Out of memory and back from the storage: the same values, the same diff.
          reload(unquote(backend), branch.id)
          reload(unquote(backend), fork.id)
          same!(inside(branch, fn -> db(get!(created.id)) end), created_ref)
          same!(inside(branch, fn -> db(get!(seeded)) end), updated_ref)
          same!(inside(fork, fn -> db(get!(created.id)) end), created_ref)
          assert diff!(branch) === changes
          assert diff!(fork) === changes

          # The row nobody touched is never stale, and the merge writes what the database would have written.
          assert {:ok, %Result{stale: []}} = Ramal.merge(branch, authorize?: false)
          same!(db(get!(created.id)), created_ref)
          same!(db(get!(seeded)), updated_ref)
          same!(db(get!(untouched)), untouched_values)

          :ok = Ramal.discard(fork)
        end
      end
    end
  end

  describe "values that a default string or a naive codec would change" do
    setup do
      start_supervised!(
        {Ramal.Supervisor,
         storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo, idle_timeout: 100}
      )

      {:ok, branch} = Ramal.branch(Customs)
      {:ok, branch: branch}
    end

    test "an empty label stays \"\" and a padded one stays padded, in the branch, in storage and after the merge",
         %{
           branch: branch
         } do
      {empty, padded, missing} =
        inside(branch, fn ->
          {create!(%{label: ""}), create!(%{label: "  a  "}), create!(%{label: nil})}
        end)

      assert {empty.label, padded.label, missing.label} === {"", "  a  ", nil}

      reload(:postgres, branch.id)

      assert inside(branch, fn -> Enum.map([empty, padded, missing], &get!(&1.id).label) end) ===
               ["", "  a  ", nil]

      assert {:ok, %Result{replayed: 3}} = Ramal.merge(branch, authorize?: false)
      assert Enum.map([empty, padded, missing], &get!(&1.id).label) === ["", "  a  ", nil]
    end

    test "a payload with nested lists of maps and keys that look like the codec's markers survives storage",
         %{
           branch: branch
         } do
      payload = %{
        "$a" => "x",
        "$m" => [%{"$t" => [1, 2], "b" => nil}, %{}],
        "list" => [[%{"k" => [true, false, "", nil]}], []],
        "z" => 1,
        "a" => 2
      }

      entry = inside(branch, fn -> create!(%{payload: payload}) end)
      same!(entry.payload, payload)

      reload(:postgres, branch.id)
      same!(inside(branch, fn -> get!(entry.id).payload end), payload)

      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      same!(get!(entry.id).payload, payload)
    end

    test "a struct whose embedded form differs from the database's survives storage as the struct",
         %{
           branch: branch
         } do
      entry = inside(branch, fn -> create!(%{point: %{"lat" => 1, "lon" => 2.5}}) end)
      same!(entry.point, %Point{lat: 1.0, lon: 2.5})

      reload(:postgres, branch.id)
      same!(inside(branch, fn -> get!(entry.id).point end), %Point{lat: 1.0, lon: 2.5})

      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      same!(get!(entry.id).point, %Point{lat: 1.0, lon: 2.5})
    end
  end

  describe "staleness" do
    setup do
      start_supervised!(
        {Ramal.Supervisor,
         storage: Ramal.Storage.Postgres, repo: Ramal.TestRepo, idle_timeout: 100}
      )

      {:ok, branch} = Ramal.branch(Customs)
      {:ok, branch: branch}
    end

    test "a row is fingerprinted the same when it is read again, whatever its custom values" do
      check all(attrs <- attrs_gen(), max_runs: @max_runs) do
        id = attrs |> create!() |> Map.fetch!(:id)
        fingerprint = Resource.fingerprint(get!(id))

        assert is_integer(fingerprint)
        assert fingerprint == Resource.fingerprint(get!(id))

        assert fingerprint ==
                 Resource.fingerprint(Ash.get!(Entry, id, authorize?: false, load: []))
      end
    end

    test "a row read and not touched is not stale after the branch is stored and reloaded" do
      check all(attrs <- attrs_gen(), max_runs: @max_runs) do
        {:ok, branch} = Ramal.branch(Customs)
        id = attrs |> create!() |> Map.fetch!(:id)
        inside(branch, fn -> get!(id) end)
        reload(:postgres, branch.id)

        assert {:ok, %Result{stale: [], replayed: 0}} = Ramal.merge(branch, authorize?: false)
      end
    end

    test "a row that changed in the database after the branch read it is stale, so the check is not vacuous",
         %{
           branch: branch
         } do
      entry = create!(%{label: "a", payload: %{"x" => [%{"y" => 1}]}, point: [1.0, 2.0]})
      inside(branch, fn -> Ash.update!(get!(entry.id), %{label: "b"}, authorize?: false) end)
      Ash.update!(entry, %{payload: %{"x" => [%{"y" => 2}]}}, authorize?: false)
      reload(:postgres, branch.id)

      assert {:error, %Error{reason: :stale}} = Ramal.merge(branch, authorize?: false)
    end
  end

  describe "a nested fork" do
    setup do
      start_supervised!(Ramal.Supervisor)
      :ok
    end

    test "merges into its parent with the values the database gives" do
      check all(first <- attrs_gen(), second <- attrs_gen(), max_runs: @max_runs) do
        {:ok, parent} = Ramal.branch(Customs)
        seeded = first |> create!() |> Map.fetch!(:id)
        updated_ref = first |> create!() |> Ash.update!(second, authorize?: false) |> db()
        created_ref = stored(second)

        {:ok, child} = Ramal.fork(parent, nested: true)

        {created, _updated} =
          inside(child, fn ->
            {create!(second), Ash.update!(get!(seeded), second, authorize?: false)}
          end)

        assert {:ok, %Result{stale: []}} = Ramal.merge(child, authorize?: false)
        same!(inside(parent, fn -> db(get!(created.id)) end), created_ref)
        same!(inside(parent, fn -> db(get!(seeded)) end), updated_ref)

        assert {:ok, %Result{stale: []}} = Ramal.merge(parent, authorize?: false)
        same!(db(get!(created.id)), created_ref)
        same!(db(get!(seeded)), updated_ref)
      end
    end
  end

  describe "the storage codecs" do
    test "an encoded state, through JSON and back, holds the same records" do
      start_supervised!(Ramal.Supervisor)

      check all(first <- attrs_gen(), second <- attrs_gen(), max_runs: @max_runs) do
        {:ok, branch} = Ramal.branch(Customs)
        seeded = first |> create!() |> Map.fetch!(:id)

        inside(branch, fn ->
          create!(second)
          Ash.update!(get!(seeded), second, authorize?: false)
        end)

        {:ok, state} = Ramal.get(branch.id)
        {:ok, encoded} = Codec.encode_state(state)
        encoded = encoded |> Jason.encode!() |> Jason.decode!()

        columns = %{
          id: state.id,
          domain: Atom.to_string(state.domain),
          name: state.name,
          status: "open"
        }

        assert {:ok, restored} = Codec.decode_state(columns, encoded)
        same!(restored.overlay, state.overlay)
        same!(restored.base, state.base)
      end
    end

    test "the write log of a durable branch keeps its values through the Postgres storage" do
      start_supervised!(Ramal.Supervisor)

      check all(first <- attrs_gen(), second <- attrs_gen(), max_runs: @max_runs) do
        # A fresh branch each run: a long-lived one folds its log into a save, and the log would be empty.
        {:ok, branch} = Ramal.branch(Customs, durable: true)
        seeded = first |> create!() |> Map.fetch!(:id)

        inside(branch, fn ->
          create!(second)
          Ash.update!(get!(seeded), second, authorize?: false)
        end)

        {:ok, state} = Ramal.get(branch.id)
        {:ok, deltas} = ETS.writes_after(%{state | wal: 0}, [])
        assert deltas != []

        # The sandbox's one connection cannot run the append of a live durable branch (docs/limits.md), so the deltas
        # the branch appended are put in the Postgres write log by hand.
        config = [repo: TestRepo]
        stored = %{state | id: Ecto.UUID.generate(), wal: 0}
        :ok = Postgres.put(stored, config)

        for {seq, delta} <- deltas, do: :ok = Postgres.append(stored, seq, delta, config)

        assert {:ok, read} = Postgres.writes_after(stored, config)
        assert Enum.map(read, &elem(&1, 0)) == Enum.map(deltas, &elem(&1, 0))

        for {{_seq, delta}, {_seq2, back}} <- Enum.zip(deltas, read) do
          same!(back.overlay, delta.overlay)
          same!(back.base, delta.base)
        end

        :ok = Postgres.delete(stored.id, config)
      end
    end
  end
end
