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

    assert ETS.list(MyApp.Farm, [], []) == {:ok, [older, newer]}
    assert ETS.list(MyApp.Farm, [status: :merged], []) == {:ok, [newer]}
    assert ETS.list(MyApp.Farm, [status: :open], []) == {:ok, [older]}
    assert ETS.list(MyApp.Other, [], []) == {:ok, [other_domain]}
  end

  test "count returns how many branches of one domain have one of the statuses" do
    branches = [
      Branch.new(MyApp.Farm),
      %{Branch.new(MyApp.Farm) | status: :proposed},
      %{Branch.new(MyApp.Farm) | status: :merged},
      Branch.new(MyApp.Other)
    ]

    for branch <- branches, do: :ok = ETS.put(branch, [])

    assert ETS.count(MyApp.Farm, [:open, :proposed], []) == {:ok, 2}
    assert ETS.count(MyApp.Farm, [:merged], []) == {:ok, 1}
    assert ETS.count(MyApp.Farm, [:discarded], []) == {:ok, 0}
    assert ETS.count(MyApp.Farm, [], []) == {:ok, 0}
    assert ETS.count(MyApp.Other, [:open], []) == {:ok, 1}
  end

  @tag supervisor: false
  test "without Ramal.Supervisor the backend reports :storage instead of crashing" do
    assert {:error, %Error{reason: :storage}} = ETS.put(Branch.new(MyApp.Farm), [])
    assert {:error, %Error{reason: :storage}} = ETS.fetch("x", [])
    assert {:error, %Error{reason: :storage}} = ETS.delete("x", [])
    assert {:error, %Error{reason: :storage}} = ETS.count(MyApp.Farm, [:open], [])
  end

  describe "fencing by epoch" do
    setup do
      branch = Branch.new(MyApp.Farm)
      :ok = ETS.put(branch, [])
      {:ok, branch: branch}
    end

    test "each claim takes the next epoch and returns the stored branch with it", %{
      branch: branch
    } do
      assert {:ok, %{epoch: 1} = claimed} = ETS.claim(branch.id, [])
      assert %{claimed | epoch: nil} == branch
      assert {:ok, %{epoch: 2}} = ETS.claim(branch.id, [])
    end

    test "the epoch is a token and not part of what is stored", %{branch: branch} do
      {:ok, held} = ETS.claim(branch.id, [])
      :ok = ETS.put(%{held | name: "renamed"}, [])

      assert {:ok, %{name: "renamed", epoch: nil}} = ETS.fetch(branch.id, [])
    end

    test "a write by the holder of an older epoch is refused and changes nothing", %{
      branch: branch
    } do
      {:ok, old} = ETS.claim(branch.id, [])
      {:ok, _newer} = ETS.claim(branch.id, [])

      assert {:error, %Error{reason: :fenced, details: %{id: id, epoch: 1}}} =
               ETS.put(%{old | name: "stale"}, [])

      assert id == branch.id
      assert {:ok, %{name: nil}} = ETS.fetch(branch.id, [])
    end

    test "a merge mark by the holder of an older epoch is refused", %{branch: branch} do
      {:ok, old} = ETS.claim(branch.id, [])
      {:ok, current} = ETS.claim(branch.id, [])

      assert {:error, %Error{reason: :fenced}} = ETS.mark_merged(old, [])
      assert {:ok, %{status: :open}} = ETS.fetch(branch.id, [])
      assert ETS.mark_merged(current, []) == :ok
      assert {:ok, %{status: :merged}} = ETS.fetch(branch.id, [])
    end

    test "a write with no epoch is not fenced", %{branch: branch} do
      {:ok, _held} = ETS.claim(branch.id, [])

      assert ETS.put(%{branch | name: "plain"}, []) == :ok
    end

    test "claiming a branch that is not there is :not_found" do
      assert {:error, %Error{reason: :not_found, details: %{id: "nope"}}} = ETS.claim("nope", [])
    end
  end
end
