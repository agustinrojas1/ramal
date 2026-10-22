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
end
