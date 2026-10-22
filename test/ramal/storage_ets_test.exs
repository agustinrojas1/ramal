defmodule Ramal.Storage.ETSTest do
  use Ramal.BranchCase

  alias Ramal.Storage.ETS

  test "a stored branch is fetched back unchanged" do
    branch = %{Branch.new(MyApp.Farm) | overlay: %{{Herd, 1} => :deleted}}

    assert ETS.put(branch, []) == :ok
    assert ETS.fetch(branch.id, []) == {:ok, branch}
  end

  test "putting again replaces the earlier copy" do
    branch = Branch.new(MyApp.Farm)
    :ok = ETS.put(branch, [])
    :ok = ETS.put(%{branch | name: "renamed"}, [])

    assert {:ok, %{name: "renamed"}} = ETS.fetch(branch.id, [])
  end

  test "fetching an unknown id is a :not_found error that names the id" do
    assert {:error, %Error{reason: :not_found, details: %{id: "nope"}} = error} =
             ETS.fetch("nope", [])

    assert error.message =~ "nope"
  end

  test "deleting removes the branch, and deleting a missing one is fine" do
    branch = Branch.new(MyApp.Farm)
    :ok = ETS.put(branch, [])

    assert ETS.delete(branch.id, []) == :ok
    assert {:error, %Error{reason: :not_found}} = ETS.fetch(branch.id, [])
    assert ETS.delete(branch.id, []) == :ok
  end

  test "list returns the branches of one domain, oldest first, optionally by status" do
    older = %{Branch.new(MyApp.Farm) | inserted_at: ~U[2026-01-01 00:00:00Z]}
    newer = %{Branch.new(MyApp.Farm) | inserted_at: ~U[2026-02-01 00:00:00Z], status: :merged}
    other_domain = Branch.new(MyApp.Other)
    for branch <- [newer, other_domain, older], do: :ok = ETS.put(branch, [])

    assert ETS.list(MyApp.Farm, [], []) == [older, newer]
    assert ETS.list(MyApp.Farm, [status: :merged], []) == [newer]
    assert ETS.list(MyApp.Farm, [status: :open], []) == [older]
    assert ETS.list(MyApp.Other, [], []) == [other_domain]
  end

  @tag supervisor: false
  test "without Ramal.Supervisor the backend reports :storage instead of crashing" do
    assert {:error, %Error{reason: :storage}} = ETS.put(Branch.new(MyApp.Farm), [])
    assert {:error, %Error{reason: :storage}} = ETS.fetch("x", [])
    assert {:error, %Error{reason: :storage}} = ETS.delete("x", [])
  end
end
