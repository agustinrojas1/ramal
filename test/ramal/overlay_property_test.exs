defmodule Ramal.OverlayPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ramal.Overlay

  # The model: a base with rows 1 and 2 of two resources, and random create/update/delete operations on keys 1..4.
  # An operation that the "database" would refuse (creating an existing row, touching a missing one) is skipped,
  # which is what the write layer guarantees before the overlay is ever involved.
  @resources [Herd, Paddock]
  @base for resource <- @resources,
            key <- 1..2,
            into: %{},
            do: {{resource, key}, %{id: key, v: 0, tag: "base"}}

  defp operation do
    gen all(
          kind <- member_of([:create, :update, :delete]),
          resource <- member_of(@resources),
          key <- integer(1..4),
          value <- integer(0..5)
        ) do
      {kind, {resource, key}, value}
    end
  end

  defp operations, do: list_of(operation(), max_length: 30)

  defp start, do: %{live: @base, overlay: Overlay.new(), snapshots: %{}}

  defp run(operations, state \\ start()), do: Enum.reduce(operations, state, &apply_operation/2)

  defp apply_operation({kind, {_, key} = ref, value}, state) do
    record = %{id: key, v: value, tag: "branch"}
    snapshots = snapshot_at_first_touch(state, ref)
    state = %{state | snapshots: snapshots}

    case {kind, Map.has_key?(state.live, ref)} do
      {:create, false} ->
        %{
          state
          | live: Map.put(state.live, ref, record),
            overlay: Overlay.put_created(state.overlay, ref, record)
        }

      {:update, true} ->
        %{
          state
          | live: Map.put(state.live, ref, record),
            overlay: Overlay.put_updated(state.overlay, ref, record)
        }

      {:delete, true} ->
        %{
          state
          | live: Map.delete(state.live, ref),
            overlay: Overlay.put_deleted(state.overlay, ref)
        }

      _refused ->
        state
    end
  end

  defp snapshot_at_first_touch(%{snapshots: snapshots}, ref) do
    case {Map.has_key?(snapshots, ref), Map.fetch(@base, ref)} do
      {false, {:ok, row}} -> Map.put(snapshots, ref, row)
      _already_taken_or_not_in_base -> snapshots
    end
  end

  defp apply_changes(base, changes) do
    Enum.reduce(changes, base, fn %{resource: resource, key: key, kind: kind, changes: changes},
                                  acc ->
      ref = {resource, key}

      after_values =
        Map.new(changes, fn {name, {_before, after_value}} -> {name, after_value} end)

      case kind do
        :created -> Map.put(acc, ref, after_values)
        :updated -> Map.update!(acc, ref, &Map.merge(&1, after_values))
        :deleted -> Map.delete(acc, ref)
      end
    end)
  end

  defp live_rows(live, resource), do: for({{^resource, _}, row} <- live, do: row)

  defp base_rows_matching(resource, predicate) do
    for {{^resource, _}, row} <- @base, predicate.(row), do: row
  end

  # A total order (value descending, then id), so the expected result is unique.
  defp comparator(a, b), do: {-a.v, a.id} <= {-b.v, b.id}

  property "applying the diff to the base gives the state the operations produced" do
    check all(operations <- operations(), max_runs: 300) do
      state = run(operations)

      assert {:ok, changes} = Overlay.diff(state.overlay, state.snapshots)
      assert apply_changes(@base, changes) == state.live
    end
  end

  property "the overlay never records a row the operations left identical to the base as a created or deleted one" do
    check all(operations <- operations(), max_runs: 300) do
      state = run(operations)

      for {ref, entry} <- state.overlay do
        case entry do
          {:created, _} -> refute Map.has_key?(@base, ref)
          :deleted -> assert Map.has_key?(@base, ref) and not Map.has_key?(state.live, ref)
          {:updated, _} -> assert Map.has_key?(@base, ref) and Map.has_key?(state.live, ref)
        end
      end
    end
  end

  property "patch returns exactly the live rows that satisfy the predicate, and never a deleted one" do
    check all(
            operations <- operations(),
            resource <- member_of(@resources),
            threshold <- integer(0..5),
            max_runs: 300
          ) do
      state = run(operations)
      predicate = &(&1.v >= threshold)
      slice = Overlay.slice(state.overlay, resource)

      patched =
        Overlay.patch(base_rows_matching(resource, predicate), slice, predicate, key: & &1.id)

      assert Enum.sort_by(patched, & &1.id) ==
               state.live
               |> live_rows(resource)
               |> Enum.filter(predicate)
               |> Enum.sort_by(& &1.id)

      deleted_keys = for {key, :deleted} <- slice, do: key
      assert Enum.all?(patched, &(&1.id not in deleted_keys))
    end
  end

  property "patch applies sort, offset and limit to the patched rows, not to the base rows" do
    check all(
            operations <- operations(),
            resource <- member_of(@resources),
            threshold <- integer(0..5),
            offset <- integer(0..3),
            limit <- one_of([constant(nil), integer(0..4)]),
            max_runs: 300
          ) do
      state = run(operations)
      predicate = &(&1.v >= threshold)
      slice = Overlay.slice(state.overlay, resource)

      patched =
        Overlay.patch(base_rows_matching(resource, predicate), slice, predicate,
          key: & &1.id,
          sort: &comparator/2,
          offset: offset,
          limit: limit
        )

      expected =
        state.live
        |> live_rows(resource)
        |> Enum.filter(predicate)
        |> Enum.sort(&comparator/2)
        |> Enum.drop(offset)
        |> then(&if(limit, do: Enum.take(&1, limit), else: &1))

      assert patched == expected
      assert Enum.all?(patched, predicate)
      if limit, do: assert(length(patched) <= limit)
    end
  end

  property "a fork's overlay is independent of its parent's later changes, and the other way round" do
    check all(
            shared <- operations(),
            parent_later <- operations(),
            fork_later <- operations(),
            max_runs: 300
          ) do
      parent = run(shared)
      fork = %{parent | overlay: Overlay.merge_into(Overlay.new(), parent.overlay)}
      assert fork.overlay == parent.overlay

      parent_after = run(parent_later, parent)
      fork_after = run(fork_later, fork)

      assert parent_after.overlay == run(shared ++ parent_later).overlay
      assert fork_after.overlay == run(shared ++ fork_later).overlay
      assert fork.overlay == parent.overlay
    end
  end

  property "slice returns only the entries of the asked resource" do
    check all(operations <- operations(), resource <- member_of(@resources), max_runs: 200) do
      state = run(operations)
      slice = Overlay.slice(state.overlay, resource)

      expected = for {{^resource, key}, entry} <- state.overlay, into: %{}, do: {key, entry}
      assert slice == expected
    end
  end
end
