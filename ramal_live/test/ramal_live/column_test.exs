defmodule RamalLive.ColumnTest do
  use ExUnit.Case, async: true

  alias Ramal.{Branch, Change}
  alias RamalLive.Column

  defp branch(attrs \\ []) do
    Map.merge(
      %{Branch.new(MyApp.Farm, name: "R7 to L18") | inserted_at: ~U[2026-10-22 12:00:00Z]},
      Map.new(attrs)
    )
  end

  describe "build/2" do
    test "carries the facts the page shows" do
      branch =
        branch(
          overlay: %{{MyApp.Herd, 1} => :deleted, {MyApp.Herd, 2} => :deleted},
          log: [:a, :b, :c]
        )

      column = Column.build(branch, [])

      assert %{id: id, name: "R7 to L18", status: :open, overlay_size: 2, write_count: 3} = column
      assert id == branch.id
      assert column.forked_from == nil
      assert column.proposal == nil
    end

    test "a fork shows where it came from" do
      parent = branch()
      assert Column.build(Branch.fork(parent), []).forked_from == parent.id
    end

    test "a change becomes before and after rows, sorted by attribute" do
      change = %Change{
        resource: MyApp.Farm.Herd,
        key: "R7",
        kind: :updated,
        changes: %{head: {30, 31}, name: {"R7", "R7b"}, paddock_id: {nil, "L18"}}
      }

      assert %{changes: [shown]} = Column.build(branch(), [change])

      assert shown.kind == :updated
      assert shown.resource == "Herd"
      assert shown.resource_title == "MyApp.Farm.Herd"
      assert shown.key == "R7"

      assert shown.rows == [
               %{
                 attribute: "head",
                 before: "30",
                 after: "31",
                 before_id?: false,
                 after_id?: false
               },
               %{
                 attribute: "name",
                 before: "R7",
                 after: "R7b",
                 before_id?: false,
                 after_id?: false
               },
               %{
                 attribute: "paddock_id",
                 before: "nil",
                 after: "L18",
                 before_id?: false,
                 after_id?: false
               }
             ]
    end

    test "a sensitive attribute keeps its row but not its values" do
      alias RamalLive.Test.Farm.Herd

      change = %Change{
        resource: Herd,
        key: "R7",
        kind: :updated,
        changes: %{head: {30, 31}, vet_pin: {"1111", "2222"}}
      }

      assert %{changes: [shown]} = Column.build(branch(), [change])

      assert shown.rows == [
               %{
                 attribute: "head",
                 before: "30",
                 after: "31",
                 before_id?: false,
                 after_id?: false
               },
               %{
                 attribute: "vet_pin",
                 before: "[redacted]",
                 after: "[redacted]",
                 before_id?: false,
                 after_id?: false
               }
             ]
    end

    test "shows the first changes and counts the rest" do
      changes =
        for n <- 1..130,
            do: %Change{resource: MyApp.Herd, key: n, kind: :created, changes: %{head: {nil, n}}}

      column = Column.build(branch(), changes)

      assert length(column.changes) == 100
      assert column.hidden_changes == 30
      assert Column.change_count(column) == 130
      assert hd(column.changes).key == "1"
    end

    test "a proposal shows who proposed it and why" do
      proposed =
        Branch.propose(
          branch(),
          %{name: "agent-3"},
          "R7 is crowding L07",
          ~U[2026-10-22 12:30:00Z]
        )

      column = Column.build(proposed, [])

      assert column.status == :proposed
      assert column.proposal == %{proposer: "%{name: \"agent-3\"}", reason: "R7 is crowding L07"}
    end

    test "a proposal without a proposer reads as unknown" do
      proposed = Branch.propose(branch(), nil, nil, ~U[2026-10-22 12:30:00Z])
      assert Column.build(proposed, []).proposal == %{proposer: "unknown", reason: nil}
    end
  end

  test "an unreadable diff keeps the branch's facts and says what went wrong" do
    column = Column.build_unreadable(branch(), "missing snapshot")
    assert column.problem == "missing snapshot"
    assert column.name == "R7 to L18"
    assert column.changes == []
  end

  describe "sort/1" do
    test "open branches first, then proposals, each oldest first" do
      open = fn id, at -> %Column{id: id, status: :open, inserted_at: at} end
      proposed = fn id, at -> %Column{id: id, status: :proposed, inserted_at: at} end

      columns = [
        proposed.("p-old", ~U[2026-01-01 00:00:00Z]),
        open.("o-new", ~U[2026-03-01 00:00:00Z]),
        open.("o-old", ~U[2026-02-01 00:00:00Z]),
        proposed.("p-new", ~U[2026-04-01 00:00:00Z])
      ]

      assert columns |> Column.sort() |> Enum.map(& &1.id) == ["o-old", "o-new", "p-old", "p-new"]
    end

    test "equal ages are ordered by id, so the order is total" do
      at = ~U[2026-01-01 00:00:00Z]
      columns = for id <- ["c", "a", "b"], do: %Column{id: id, status: :open, inserted_at: at}
      assert columns |> Column.sort() |> Enum.map(& &1.id) == ["a", "b", "c"]
    end
  end

  describe "age/2" do
    @now ~U[2026-10-22 12:00:00Z]

    test "one number and one unit" do
      assert Column.age(~U[2026-10-22 11:59:48Z], @now) == "12s"
      assert Column.age(~U[2026-10-22 11:55:30Z], @now) == "4m"
      assert Column.age(~U[2026-10-22 09:00:00Z], @now) == "3h"
      assert Column.age(~U[2026-10-20 12:00:00Z], @now) == "2d"
    end

    test "the boundaries belong to the larger unit" do
      assert Column.age(~U[2026-10-22 11:59:00Z], @now) == "1m"
      assert Column.age(~U[2026-10-22 11:00:00Z], @now) == "1h"
      assert Column.age(~U[2026-10-21 12:00:00Z], @now) == "1d"
    end

    test "a time in the future is zero seconds" do
      assert Column.age(~U[2026-10-22 12:00:30Z], @now) == "0s"
    end
  end

  describe "format_value/1" do
    test "strings as they are, everything else as inspect prints it" do
      assert Column.format_value("L18") == "L18"
      assert Column.format_value(31) == "31"
      assert Column.format_value(nil) == "nil"
      assert Column.format_value(:ok) == ":ok"
      assert Column.format_value(~D[2026-10-22]) == "~D[2026-10-22]"
    end

    test "a long value is cut with an ellipsis" do
      long = String.duplicate("x", 200)
      cut = Column.format_value(long)
      assert String.length(cut) == 80
      assert String.ends_with?(cut, "…")
    end

    test "a binary that is not text is inspected" do
      assert Column.format_value(<<0, 255, 1>>) == "<<0, 255, 1>>"
    end

    test "a large collection is abbreviated" do
      assert Column.format_value(Enum.to_list(1..100)) =~ "..."
    end
  end

  describe "id?/1" do
    test "is true for a UUID in either case" do
      assert Column.id?("dfac6113-e2de-485c-819f-8ac2ee688cb5")
      assert Column.id?("DFAC6113-E2DE-485C-819F-8AC2EE688CB5")
    end

    test "is false for anything else" do
      refute Column.id?("R7")
      refute Column.id?("dfac6113-e2de-485c-819f-8ac2ee688cb5 and more")
      refute Column.id?("nil")
      refute Column.id?(nil)
    end
  end

  test "a change flags the UUIDs of its key and cells, so the page can keep them on one line" do
    id = "dfac6113-e2de-485c-819f-8ac2ee688cb5"

    change = %Change{
      resource: MyApp.Farm.Herd,
      key: id,
      kind: :updated,
      changes: %{paddock_id: {id, "L18"}}
    }

    assert %{changes: [shown]} = Column.build(branch(), [change])
    assert shown.key_id?
    assert [%{before_id?: true, after_id?: false}] = shown.rows
  end

  test "short_id keeps eight characters" do
    assert Column.short_id("dfac6113-e2de-485c-819f-8ac2ee688cb5") == "dfac6113"
    assert Column.short_id("b1") == "b1"
  end
end
