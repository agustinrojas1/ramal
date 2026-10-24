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

  test "a branch that changes status is listed under the new one only" do
    branch = Branch.new(MyApp.Farm)
    :ok = ETS.put(branch, [])
    assert ETS.list(MyApp.Farm, [status: :open], []) == {:ok, [branch]}

    proposed = %{branch | status: :proposed}
    :ok = ETS.put(proposed, [])
    assert ETS.list(MyApp.Farm, [status: :open], []) == {:ok, []}
    assert ETS.list(MyApp.Farm, [status: :proposed], []) == {:ok, [proposed]}

    # `mark_merged/2` writes the row without going through `put/2`, so it moves the index entry itself.
    :ok = ETS.mark_merged(proposed, [])
    assert ETS.list(MyApp.Farm, [status: :proposed], []) == {:ok, []}
    assert {:ok, [%{status: :merged}]} = ETS.list(MyApp.Farm, [status: :merged], [])
    assert {:ok, [%{status: :merged}]} = ETS.list(MyApp.Farm, [], [])

    :ok = ETS.delete(branch.id, [])
    assert ETS.list(MyApp.Farm, [], []) == {:ok, []}
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

  describe "the write log" do
    defp durable(wal \\ 0), do: %{Branch.new(MyApp.Farm, durable: true) | wal: wal}

    defp delta(n),
      do: %{overlay: %{}, gone: [{Herd, n}], base: %{}, log: [], seen: %{}, next_placeholder: 0}

    defp append_all(branch, seqs),
      do: for(seq <- seqs, do: :ok = ETS.append(branch, seq, delta(seq), []))

    test "the deltas after the branch's wal come back oldest first" do
      branch = durable()
      append_all(branch, [3, 1, 2, 10])

      assert ETS.writes_after(branch, []) ==
               {:ok, [{1, delta(1)}, {2, delta(2)}, {3, delta(3)}, {10, delta(10)}]}

      assert ETS.writes_after(%{branch | wal: 2}, []) == {:ok, [{3, delta(3)}, {10, delta(10)}]}
      assert ETS.writes_after(%{branch | wal: 10}, []) == {:ok, []}
    end

    test "the deltas of other branches are not returned" do
      one = durable()
      other = durable()
      append_all(one, [1, 2])
      append_all(other, [1])

      assert ETS.writes_after(one, []) == {:ok, [{1, delta(1)}, {2, delta(2)}]}
      assert ETS.writes_after(other, []) == {:ok, [{1, delta(1)}]}
    end

    test "putting a durable branch deletes the deltas its wal covers, and only those" do
      branch = durable()
      append_all(branch, [1, 2, 3])

      assert ETS.put(%{branch | wal: 2}, []) == :ok

      assert ETS.writes_after(branch, []) == {:ok, [{3, delta(3)}]}
      assert {:ok, %{wal: 2}} = ETS.fetch(branch.id, [])
    end

    test "putting a branch that is not durable leaves the log alone" do
      branch = %{durable() | durable: false}
      append_all(branch, [1])

      assert ETS.put(%{branch | wal: 5}, []) == :ok
      assert ETS.writes_after(branch, []) == {:ok, [{1, delta(1)}]}
    end

    test "deleting a branch deletes its log" do
      branch = durable()
      other = durable()
      append_all(branch, [1, 2])
      append_all(other, [1])
      :ok = ETS.put(branch, [])

      assert ETS.delete(branch.id, []) == :ok

      assert ETS.writes_after(branch, []) == {:ok, []}
      assert ETS.writes_after(other, []) == {:ok, [{1, delta(1)}]}
    end

    test "listing and counting see branches only" do
      branch = durable()
      :ok = ETS.put(branch, [])
      append_all(branch, [1, 2])

      assert ETS.list(MyApp.Farm, [], []) == {:ok, [branch]}
      assert ETS.count(MyApp.Farm, [:open], []) == {:ok, 1}
    end

    @tag supervisor: false
    test "without Ramal.Supervisor it reports :storage too" do
      assert {:error, %Error{reason: :storage}} = ETS.append(durable(), 1, delta(1), [])
      assert {:error, %Error{reason: :storage}} = ETS.writes_after(durable(), [])
    end
  end

  @tag supervisor: false
  test "without Ramal.Supervisor the backend reports :storage instead of crashing" do
    assert {:error, %Error{reason: :storage}} = ETS.put(Branch.new(MyApp.Farm), [])
    assert {:error, %Error{reason: :storage}} = ETS.fetch("x", [])
    assert {:error, %Error{reason: :storage}} = ETS.delete("x", [])
    assert {:error, %Error{reason: :storage}} = ETS.count(MyApp.Farm, [:open], [])
  end

  describe "the write log of a branch with an epoch" do
    setup do
      branch = %{Branch.new(MyApp.Farm, durable: true) | wal: 0}
      :ok = ETS.put(branch, [])
      {:ok, branch: branch}
    end

    test "the holder of the current epoch appends and reads the log", %{branch: branch} do
      {:ok, held} = ETS.claim(branch.id, [])

      assert ETS.append(held, 1, delta(1), []) == :ok
      assert ETS.writes_after(held, []) == {:ok, [{1, delta(1)}]}
    end

    test "the holder of an older epoch is refused and stores nothing", %{branch: branch} do
      {:ok, old} = ETS.claim(branch.id, [])
      {:ok, newer} = ETS.claim(branch.id, [])

      assert {:error, %Error{reason: :fenced, details: %{epoch: 1}}} =
               ETS.append(old, 1, delta(1), [])

      assert ETS.writes_after(newer, []) == {:ok, []}
      assert ETS.append(newer, 1, delta(2), []) == :ok
    end

    test "the next holder reads every delta the earlier one stored, and the earlier one can read none",
         %{
           branch: branch
         } do
      {:ok, old} = ETS.claim(branch.id, [])
      :ok = ETS.append(old, 1, delta(1), [])
      :ok = ETS.append(old, 2, delta(2), [])
      {:ok, newer} = ETS.claim(branch.id, [])

      assert ETS.writes_after(newer, []) == {:ok, [{1, delta(1)}, {2, delta(2)}]}
      assert {:error, %Error{reason: :fenced}} = ETS.writes_after(old, [])
      assert {:error, %Error{reason: :fenced}} = ETS.append(old, 3, delta(3), [])
    end

    test "a snapshot of the holder deletes the deltas it covers, and one of an older epoch deletes none",
         %{
           branch: branch
         } do
      {:ok, old} = ETS.claim(branch.id, [])
      :ok = ETS.append(old, 1, delta(1), [])
      {:ok, newer} = ETS.claim(branch.id, [])

      assert {:error, %Error{reason: :fenced}} = ETS.put(%{old | wal: 1}, [])
      assert ETS.writes_after(newer, []) == {:ok, [{1, delta(1)}]}

      assert ETS.put(%{newer | wal: 1}, []) == :ok
      assert ETS.writes_after(%{newer | wal: 0}, []) == {:ok, []}
    end

    test "a branch without an epoch is written unconditionally, whatever the epoch of the row", %{
      branch: branch
    } do
      {:ok, _claimed} = ETS.claim(branch.id, [])

      assert branch.epoch == nil
      assert ETS.append(branch, 1, delta(1), []) == :ok
      assert ETS.writes_after(branch, []) == {:ok, [{1, delta(1)}]}
    end
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
