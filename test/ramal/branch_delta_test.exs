defmodule Ramal.BranchDeltaTest do
  # The delta of the write log (ADR 0048) on plain data: what one action added to a branch, and the branch that results
  # from applying the deltas of its actions in the order they ended in. No process, no storage.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ramal.Branch

  @at ~U[2026-01-01 00:00:00Z]

  defp entry(type, key), do: {type, Herd, type, %{key: key}, nil, [key: key], @at}

  # Rows 1 and 2 are in the base; 3 and 4 are not.
  defp base_row(key), do: %{fingerprint: key * 7, snapshot: %{id: key, name: "base"}}

  # One captured write of the action, as the capture hook makes it. `nil` when the row cannot take it, as the data layer
  # would refuse it (updating a row that is not there, creating one that is).
  defp write(branch, key, :write, n) do
    ref = {Herd, key}
    record = %{id: key, name: "v#{n}"}

    case {Map.get(branch.overlay, ref), key <= 2} do
      {nil, true} ->
        Branch.put_write(branch, :updated, ref, record, base_row(key), entry(:update, key))

      {nil, false} ->
        Branch.put_write(branch, :created, ref, record, nil, entry(:create, key))

      {:deleted, _} ->
        nil

      {_held, _} ->
        Branch.put_write(branch, :updated, ref, record, nil, entry(:update, key))
    end
  end

  defp write(branch, key, :destroy, _n) do
    ref = {Herd, key}

    case {Map.get(branch.overlay, ref), key <= 2} do
      {nil, true} ->
        Branch.put_write(branch, :deleted, ref, %{id: key}, base_row(key), entry(:destroy, key))

      {nil, false} ->
        nil

      {:deleted, _} ->
        nil

      {_held, _} ->
        Branch.put_write(branch, :deleted, ref, %{id: key}, nil, entry(:destroy, key))
    end
  end

  # Runs the steps, `{key, kind, ends?}`: an action ends after a step with `ends?`. Returns the branch, and the branch
  # rebuilt from the deltas of its actions alone.
  defp run(steps) do
    start = Branch.new(MyApp.Farm, durable: true)

    {branch, replica, undos, _n} =
      Enum.reduce(steps, {start, start, [], 0}, fn {key, kind, ends?},
                                                   {branch, replica, undos, n} ->
        {branch, undos} =
          case write(branch, key, kind, n) do
            nil -> {branch, undos}
            {branch, undo} -> {branch, [undo | undos]}
          end

        if ends? and undos != [] do
          seq = replica.wal + 1
          {branch, apply_delta(replica, seq, Branch.delta(branch, undos)), [], n + 1}
        else
          {branch, replica, undos, n + 1}
        end
      end)

    # An action that has not ended is not in the replica, nor in a delta.
    {branch, replica, undos}
  end

  defp apply_delta(replica, seq, delta), do: Branch.apply_delta(replica, seq, delta)

  defp steps do
    list_of(
      tuple({integer(1..4), member_of([:write, :write, :destroy]), boolean()}),
      max_length: 25
    )
  end

  property "the deltas of the actions that ended rebuild the branch they were taken from" do
    check all(steps <- steps()) do
      # Close the last action, so that nothing is left running.
      {branch, replica, _running} = run(steps ++ [{1, :write, true}, {3, :write, true}])

      assert replica.overlay == branch.overlay
      assert replica.base == branch.base
      assert replica.log == branch.log
    end
  end

  property "a delta holds only the rows its action wrote" do
    check all(steps <- steps()) do
      {branch, _replica, running} = run(steps)
      delta = Branch.delta(branch, running)
      written = running |> Enum.map(& &1.ref) |> MapSet.new()

      assert delta.overlay |> Map.keys() |> MapSet.new() |> MapSet.subset?(written)
      assert delta.base |> Map.keys() |> MapSet.new() |> MapSet.subset?(written)
      assert delta.gone |> MapSet.new() |> MapSet.subset?(written)
      assert length(delta.log) == length(running)
    end
  end

  test "a created row the action destroyed is gone, not deleted" do
    branch = Branch.new(MyApp.Farm, durable: true)

    {branch, create} =
      Branch.put_write(branch, :created, {Herd, 3}, %{id: 3}, nil, entry(:create, 3))

    {branch, destroy} =
      Branch.put_write(branch, :deleted, {Herd, 3}, %{id: 3}, nil, entry(:destroy, 3))

    delta = Branch.delta(branch, [destroy, create])

    assert delta.overlay == %{}
    assert delta.gone == [{Herd, 3}]
    assert Enum.map(delta.log, &elem(&1, 0)) == [:create, :destroy]
  end

  test "applying a delta takes a row's entry out of the branch when the action's end left none" do
    start = Branch.new(MyApp.Farm, durable: true)

    {with_row, create} =
      Branch.put_write(start, :created, {Herd, 3}, %{id: 3}, nil, entry(:create, 3))

    replica = Branch.apply_delta(start, 1, Branch.delta(with_row, [create]))
    assert replica.overlay == with_row.overlay

    {gone, destroy} =
      Branch.put_write(with_row, :deleted, {Herd, 3}, %{id: 3}, nil, entry(:destroy, 3))

    replica = Branch.apply_delta(replica, 2, Branch.delta(gone, [destroy]))

    assert replica.overlay == %{}
    assert replica.wal == 2
    assert length(replica.log) == 2
  end

  test "a row written twice by one action is in the delta once, with its last state" do
    branch = Branch.new(MyApp.Farm, durable: true)

    {branch, one} =
      Branch.put_write(
        branch,
        :updated,
        {Herd, 1},
        %{id: 1, name: "a"},
        base_row(1),
        entry(:update, 1)
      )

    {branch, two} =
      Branch.put_write(branch, :updated, {Herd, 1}, %{id: 1, name: "b"}, nil, entry(:update, 1))

    delta = Branch.delta(branch, [two, one])

    assert delta.overlay == %{{Herd, 1} => {:updated, %{id: 1, name: "b"}}}
    assert delta.base == %{{Herd, 1} => base_row(1)}
    assert length(delta.log) == 2
  end

  test "a fork starts with an empty write log and keeps the parent's durability" do
    parent = %{Branch.new(MyApp.Farm, durable: true) | wal: 12}

    fork = Branch.fork(parent)
    assert {fork.durable, fork.wal} == {true, 0}

    assert {Branch.fork(parent, durable: false).durable, Branch.fork(parent, durable: false).wal} ==
             {false, 0}

    assert Branch.fork(Branch.new(MyApp.Farm), durable: true).durable
  end

  test "a branch is not durable unless it says so" do
    branch = Branch.new(MyApp.Farm)
    assert {branch.durable, branch.wal} == {false, 0}
  end
end
