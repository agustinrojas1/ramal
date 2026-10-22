defmodule Ramal.BranchTest do
  use ExUnit.Case, async: true

  alias Ramal.Branch

  doctest Ramal.Branch

  test "a new branch is open, empty and has a fresh UUID" do
    first = Branch.new(MyApp.Farm)
    second = Branch.new(MyApp.Farm)

    assert {:ok, _} = Ecto.UUID.cast(first.id)
    assert first.id != second.id
    assert %{status: :open, overlay: %{}, log: [], base: %{}, metadata: %{}, name: nil} = first
    assert %DateTime{} = first.inserted_at
  end

  test "name and metadata are kept as given" do
    branch = Branch.new(MyApp.Farm, name: "what if", metadata: %{ticket: 7})

    assert branch.name == "what if"
    assert branch.metadata == %{ticket: 7}
  end

  test "only an open branch is open" do
    branch = Branch.new(MyApp.Farm)

    assert Branch.open?(branch)
    refute Branch.open?(%{branch | status: :merged})
    refute Branch.open?(%{branch | status: :discarded})
  end

  test "discarding empties the overlay, log and base but keeps identity" do
    branch = %{
      Branch.new(MyApp.Farm, name: "x")
      | overlay: %{{A, 1} => :deleted},
        log: [:entry],
        base: %{{A, 1} => %{}}
    }

    discarded = Branch.discard(branch)

    assert %{status: :discarded, overlay: %{}, log: [], base: %{}} = discarded

    assert {discarded.id, discarded.name, discarded.inserted_at} ==
             {branch.id, branch.name, branch.inserted_at}
  end

  describe "put_write/6 and undo/2" do
    defp entry(n), do: {:update, A, :update, %{n: n}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}

    test "the first write to an existing row keeps its snapshot and later writes keep that one" do
      branch = Branch.new(MyApp.Farm)
      {branch, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, %{n: 1}, entry(2))
      {branch, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 3}, %{n: 2}, entry(3))

      assert branch.base == %{{A, 1} => %{n: 1}}
      assert branch.overlay == %{{A, 1} => {:updated, %{n: 3}}}
      assert branch.log == [entry(3), entry(2)]
    end

    test "a created row needs no snapshot" do
      {branch, _} =
        Branch.put_write(Branch.new(MyApp.Farm), :created, {A, 1}, %{n: 1}, nil, entry(1))

      assert branch.base == %{}
      assert branch.overlay == %{{A, 1} => {:created, %{n: 1}}}
    end

    test "deleting a created row removes its overlay entry but the log keeps both writes" do
      branch = Branch.new(MyApp.Farm)
      {branch, _} = Branch.put_write(branch, :created, {A, 1}, %{n: 1}, nil, entry(1))
      {branch, _} = Branch.put_write(branch, :deleted, {A, 1}, %{n: 1}, %{n: 1}, entry(2))

      assert branch.overlay == %{}
      assert branch.base == %{}
      assert length(branch.log) == 2
    end

    test "undo takes back the newest writes and leaves the others" do
      branch = Branch.new(MyApp.Farm)
      {kept, _} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, %{n: 1}, entry(2))
      {b2, undo2} = Branch.put_write(kept, :updated, {A, 1}, %{n: 3}, %{n: 2}, entry(3))
      {b3, undo3} = Branch.put_write(b2, :deleted, {A, 2}, %{n: 9}, %{n: 9}, entry(4))

      assert Branch.undo(b3, [undo3, undo2]) == kept
    end

    test "undo leaves a write another process made in between" do
      branch = Branch.new(MyApp.Farm)
      {written, undo} = Branch.put_write(branch, :updated, {A, 1}, %{n: 2}, %{n: 1}, entry(2))
      {other, _} = Branch.put_write(written, :updated, {A, 2}, %{n: 5}, %{n: 4}, entry(5))

      undone = Branch.undo(other, [undo])
      assert undone.overlay == %{{A, 2} => {:updated, %{n: 5}}}
      assert undone.log == [entry(5)]
    end
  end
end
