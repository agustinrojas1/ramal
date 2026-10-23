defmodule Ramal.OverlayTest do
  use ExUnit.Case, async: true

  alias Ramal.{Change, Error, Overlay}

  doctest Ramal.Overlay
  doctest Ramal.Error
  doctest Ramal.Change

  @herd {Herd, 1}
  @paddock {Paddock, 1}

  defp row(id, fields \\ %{}), do: Map.merge(%{id: id, name: "n#{id}", head: 10}, fields)
  defp all(_record), do: true

  describe "put_created/3, put_updated/3 and put_deleted/2" do
    test "start from an empty overlay and record the net effect on the base" do
      assert Overlay.new() == %{}
      assert Overlay.put_created(%{}, @herd, row(1)) == %{@herd => {:created, row(1)}}
      assert Overlay.put_updated(%{}, @herd, row(1)) == %{@herd => {:updated, row(1)}}
      assert Overlay.put_deleted(%{}, @herd) == %{@herd => :deleted}
    end

    test "updating a row the branch created keeps it created, with the new record" do
      overlay =
        %{}
        |> Overlay.put_created(@herd, row(1))
        |> Overlay.put_updated(@herd, row(1, %{head: 99}))

      assert overlay == %{@herd => {:created, row(1, %{head: 99})}}
    end

    test "deleting a row the branch created leaves no trace, since the base never had it" do
      overlay = %{} |> Overlay.put_created(@herd, row(1)) |> Overlay.put_deleted(@herd)

      assert overlay == %{}
    end

    test "deleting a row twice, or after updating it, leaves it deleted" do
      updated_then_deleted =
        %{} |> Overlay.put_updated(@herd, row(1)) |> Overlay.put_deleted(@herd)

      deleted_twice = %{@herd => :deleted} |> Overlay.put_deleted(@herd)

      assert updated_then_deleted == %{@herd => :deleted}
      assert deleted_twice == %{@herd => :deleted}
    end

    test "creating a row whose base twin was deleted replaces the base row, so it is an update" do
      overlay = %{@herd => :deleted} |> Overlay.put_created(@herd, row(1, %{head: 5}))

      assert overlay == %{@herd => {:updated, row(1, %{head: 5})}}
    end

    test "putting an entry does not touch the entries of other rows or resources" do
      overlay = %{@paddock => :deleted} |> Overlay.put_created(@herd, row(1))

      assert overlay[@paddock] == :deleted
      assert overlay[@herd] == {:created, row(1)}
    end
  end

  describe "slice/2" do
    test "returns only the entries of one resource, keyed by primary key" do
      overlay = %{
        {Herd, 1} => {:created, row(1)},
        {Herd, 2} => :deleted,
        {Paddock, 1} => {:updated, row(1)}
      }

      assert Overlay.slice(overlay, Herd) == %{1 => {:created, row(1)}, 2 => :deleted}
      assert Overlay.slice(overlay, Paddock) == %{1 => {:updated, row(1)}}
      assert Overlay.slice(overlay, Move) == %{}
    end

    test "supports composite keys" do
      overlay = %{{Herd, {1, "a"}} => :deleted}

      assert Overlay.slice(overlay, Herd) == %{{1, "a"} => :deleted}
    end
  end

  describe "keys/2 and any?/2" do
    test "list the keys of one resource and say whether it has any entry" do
      overlay = %{
        {Herd, 1} => {:created, row(1)},
        {Herd, {2, "a"}} => :deleted,
        {Paddock, 1} => {:updated, row(1)}
      }

      assert Enum.sort_by(Overlay.keys(overlay, Herd), &inspect/1) == [1, {2, "a"}]
      assert Overlay.keys(overlay, Move) == []
      assert Overlay.any?(overlay, Herd)
      refute Overlay.any?(overlay, Move)
      refute Overlay.any?(%{}, Herd)
    end
  end

  describe "patch/4" do
    defp patch(base, slice, predicate \\ &all/1, opts \\ []) do
      Overlay.patch(base, slice, predicate, Keyword.merge([key: & &1.id], opts))
    end

    test "returns the base rows untouched when the slice is empty" do
      base = [row(2), row(1)]

      assert patch(base, %{}) == base
    end

    test "drops base rows the branch deleted" do
      assert patch([row(1), row(2)], %{1 => :deleted}) == [row(2)]
    end

    test "replaces base rows the branch updated" do
      updated = row(1, %{name: "changed"})

      assert patch([row(1), row(2)], %{1 => {:updated, updated}}) == [updated, row(2)]
    end

    test "builds the replacing row with :replace, which sees the base row it replaces" do
      slice = %{1 => {:updated, row(1, %{name: "changed"})}}
      replace = fn base, record -> Map.put(record, :source, base.source) end

      assert patch([Map.put(row(1), :source, :a)], slice, &all/1, replace: replace) ==
               [Map.put(row(1, %{name: "changed"}), :source, :a)]
    end

    test "drops an updated row that no longer satisfies the predicate" do
      slice = %{1 => {:updated, row(1, %{head: 0})}}

      assert patch([row(1), row(2)], slice, &(&1.head > 0)) == [row(2)]
    end

    test "adds a created row only when it satisfies the predicate" do
      slice = %{3 => {:created, row(3, %{head: 50})}, 4 => {:created, row(4, %{head: 1})}}

      assert patch([row(1)], slice, &(&1.head > 5)) == [row(1), row(3, %{head: 50})]
    end

    test "adds an updated row the base did not return because it only matches after the update" do
      slice = %{7 => {:updated, row(7, %{head: 100})}}

      assert patch([], slice, &(&1.head > 50)) == [row(7, %{head: 100})]
    end

    test "never adds a deleted entry for a row the base did not return" do
      assert patch([row(1)], %{9 => :deleted}) == [row(1)]
    end

    test "sorts base rows and overlay rows together, and keeps equal rows in their original order" do
      base = [row(1, %{head: 20}), row(2, %{head: 10})]
      slice = %{3 => {:created, row(3, %{head: 20})}}
      by_head_desc = &(&1.head >= &2.head)

      assert patch(base, slice, &all/1, sort: by_head_desc) |> Enum.map(& &1.id) == [1, 3, 2]
    end

    test "applies limit after patching, so a created row can fill a limited query" do
      base = [row(1, %{head: 10}), row(2, %{head: 20})]
      slice = %{3 => {:created, row(3, %{head: 30})}}

      result = patch(base, slice, &all/1, sort: &(&1.head >= &2.head), limit: 2)

      assert Enum.map(result, & &1.id) == [3, 2]
    end

    test "applies offset after patching and before limit" do
      base = [row(1), row(2), row(3)]

      assert patch(base, %{2 => :deleted}, &all/1, offset: 1, limit: 1) == [row(3)]
    end

    test "a limit of zero returns nothing" do
      assert patch([row(1)], %{}, &all/1, limit: 0) == []
    end

    test "requires a key function" do
      assert_raise KeyError, fn -> Overlay.patch([row(1)], %{}, &all/1, []) end
    end
  end

  describe "diff/3" do
    test "describes a created row with every attribute going from nil to its value" do
      overlay = %{@herd => {:created, row(1)}}

      assert {:ok, [change]} = Overlay.diff(overlay, %{})

      assert change == %Change{
               resource: Herd,
               key: 1,
               kind: :created,
               changes: %{id: {nil, 1}, name: {nil, "n1"}, head: {nil, 10}}
             }
    end

    test "describes an updated row with only the attributes that differ from the base snapshot" do
      overlay = %{@herd => {:updated, row(1, %{head: 99})}}
      base = %{@herd => row(1)}

      assert {:ok, [%Change{kind: :updated, changes: changes}]} = Overlay.diff(overlay, base)
      assert changes == %{head: {10, 99}}
    end

    test "leaves out an updated row whose values ended up equal to the base" do
      overlay = %{@herd => {:updated, row(1)}}

      assert Overlay.diff(overlay, %{@herd => row(1)}) == {:ok, []}
    end

    test "treats an attribute only one side has as nil on the other, and leaves out one that is nil" do
      overlay = %{@herd => {:updated, %{id: 1, added: 5, also_nil: nil}}}
      base = %{@herd => %{id: 1, removed: 7}}

      assert {:ok, [change]} = Overlay.diff(overlay, base)
      assert change.changes == %{added: {nil, 5}, removed: {7, nil}}
    end

    test "describes a deleted row with every attribute going from its base value to nil" do
      assert {:ok, [change]} = Overlay.diff(%{@herd => :deleted}, %{@herd => row(1)})

      assert change.kind == :deleted
      assert change.changes == %{id: {1, nil}, name: {"n1", nil}, head: {10, nil}}
    end

    test "ignores bookkeeping keys such as __meta__ when comparing" do
      overlay = %{@herd => {:updated, Map.put(row(1), :__meta__, :after)}}
      base = %{@herd => Map.put(row(1), :__meta__, :before)}

      assert Overlay.diff(overlay, base) == {:ok, []}
    end

    test "uses the attributes function when given one" do
      overlay = %{@herd => {:updated, %{id: 1, head: 2, noise: :a}}}
      base = %{@herd => %{id: 1, head: 1, noise: :b}}

      assert {:ok, [change]} = Overlay.diff(overlay, base, attributes: &Map.take(&1, [:head]))
      assert change.changes == %{head: {1, 2}}
    end

    test "is deterministic: changes come sorted by ref" do
      overlay = %{
        {Paddock, 2} => :deleted,
        {Herd, 9} => {:created, row(9)},
        {Herd, 3} => {:created, row(3)}
      }

      base = %{{Paddock, 2} => row(2)}

      assert {:ok, changes} = Overlay.diff(overlay, base)
      assert Enum.map(changes, &{&1.resource, &1.key}) == [{Herd, 3}, {Herd, 9}, {Paddock, 2}]
    end

    test "returns a :missing_snapshot error when an updated or deleted row has no base snapshot" do
      for entry <- [{:updated, row(1)}, :deleted] do
        assert {:error,
                %Error{reason: :missing_snapshot, details: %{resource: Herd, key: 1}} = error} =
                 Overlay.diff(%{@herd => entry}, %{})

        assert error.message =~ "Herd"
      end
    end
  end

  describe "share/3" do
    # Terms built at run time, so that a copy of one is a different term from the original.
    defp tags, do: Enum.map(1..5, &Integer.to_string/1)
    defp copy(term), do: :erlang.binary_to_term(:erlang.term_to_binary(term))

    test "returns a record equal to the one it was given" do
      record = %{id: 1, name: "R7", tags: tags(), at: DateTime.utc_now()}

      assert Overlay.share(record, []) == record
      assert Overlay.share(record, [copy(record)], 1) == record
      assert Overlay.share(record, [%{id: 2, tags: ["x"]}, %{}], "other") == record
    end

    test "points a field at the equal field of a reference, the first reference that has one" do
      record = %{id: 1, tags: copy(tags()), name: "kept"}
      first = %{tags: tags()}
      second = %{tags: tags(), name: copy("kept")}

      shared = Overlay.share(record, [first, second])

      assert shared == record
      assert :erts_debug.same(shared.tags, first.tags)
      refute :erts_debug.same(shared.tags, second.tags)
      assert :erts_debug.same(shared.name, second.name)
    end

    test "leaves a field that differs from the reference as it is" do
      record = %{tags: tags() ++ ["6"]}
      reference = %{tags: tags()}

      assert :erts_debug.same(Overlay.share(record, [reference]).tags, record.tags)
    end

    test "points a field that equals the key at the key" do
      key = String.duplicate("k", 40)
      record = %{id: copy(key), parent_id: copy(key), name: "n"}

      shared = Overlay.share(record, [], key)

      assert shared == record
      assert :erts_debug.same(shared.id, key)
      assert :erts_debug.same(shared.parent_id, key)
    end

    test "rebuilds a struct, and the structs in its fields, without changing them" do
      branch = Ramal.Branch.new(MyApp.Farm, name: "enforced keys")
      row = %{at: DateTime.utc_now(), on: Date.utc_today(), branch: branch}

      assert Overlay.share(row, []) == row
      assert Overlay.share(branch, []) == branch
      assert Overlay.share(%{row | at: DateTime.utc_now()}, [row]).on == row.on
    end

    test "returns a struct that lacks one of its fields as it is" do
      broken = Map.delete(DateTime.utc_now(), :zone_abbr)

      assert Overlay.share(broken, []) == broken
      assert Overlay.share(%{at: broken}, []) == %{at: broken}
    end
  end

  describe "merge_into/2" do
    test "merging into an empty overlay copies the other one" do
      other = %{
        @herd => {:created, row(1)},
        @paddock => :deleted,
        {Herd, 2} => {:updated, row(2)}
      }

      assert Overlay.merge_into(Overlay.new(), other) == other
    end

    test "entries of the other overlay win, combined by the usual rules" do
      overlay = %{@herd => {:created, row(1)}, {Herd, 2} => {:updated, row(2)}}

      other = %{
        @herd => :deleted,
        {Herd, 2} => {:updated, row(2, %{head: 1})},
        {Herd, 3} => :deleted
      }

      assert Overlay.merge_into(overlay, other) == %{
               {Herd, 2} => {:updated, row(2, %{head: 1})},
               {Herd, 3} => :deleted
             }
    end

    test "leaves the original overlays unchanged" do
      parent = %{@herd => {:created, row(1)}}
      fork = Overlay.merge_into(Overlay.new(), parent)
      parent_later = Overlay.put_deleted(parent, @herd)
      fork_later = Overlay.put_created(fork, @paddock, row(1))

      assert fork == %{@herd => {:created, row(1)}}
      assert parent_later == %{}
      assert fork_later == %{@herd => {:created, row(1)}, @paddock => {:created, row(1)}}
    end
  end
end
