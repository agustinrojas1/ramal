defmodule Ramal.ModelConformanceTest do
  # Ties the proofs in verification/bend to the code: the Bend model's write table must be Ramal.Overlay's, and what
  # its laws prove of the model is checked of the code on random logs. Pure, no database.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ramal.{Branch, Overlay}

  @ref {Herd, 1}

  # put_created, put_updated and put_deleted in verification/bend/model.bend, with Absent as no entry.
  @model %{
    {:absent, :created} => {:created, :r},
    {:absent, :updated} => {:updated, :r},
    {:absent, :deleted} => :deleted,
    {:created, :created} => {:created, :r},
    {:created, :updated} => {:created, :r},
    {:created, :deleted} => :absent,
    {:updated, :created} => {:updated, :r},
    {:updated, :updated} => {:updated, :r},
    {:updated, :deleted} => :deleted,
    {:deleted, :created} => {:updated, :r},
    {:deleted, :updated} => {:updated, :r},
    {:deleted, :deleted} => :deleted
  }

  defp overlay_with(:absent), do: %{}
  defp overlay_with(:deleted), do: %{@ref => :deleted}
  defp overlay_with(kind), do: %{@ref => {kind, :old}}

  defp put(overlay, :created), do: Overlay.put_created(overlay, @ref, :r)
  defp put(overlay, :updated), do: Overlay.put_updated(overlay, @ref, :r)
  defp put(overlay, :deleted), do: Overlay.put_deleted(overlay, @ref)

  defp entry(overlay), do: Map.get(overlay, @ref, :absent)

  test "Ramal.Overlay combines writes as the Bend model's put functions do" do
    for {{slot, write}, expected} <- @model do
      assert entry(put(overlay_with(slot), write)) == expected, "#{slot} then #{write}"
    end
  end

  # One row, as in the model: a base that has it or not, and a log of actions that each succeed or fail on the row
  # they find (Op and effect in model.bend).
  defp action do
    one_of([
      tuple({constant(:create), integer(0..9)}),
      tuple({constant(:set), integer(0..9)}),
      tuple({constant(:add), integer(1..3)}),
      constant(:delete)
    ])
  end

  defp effect({:create, v}, nil), do: v
  defp effect({:set, v}, row) when row != nil, do: v
  defp effect({:add, n}, row) when row != nil, do: row + n
  defp effect(:delete, row) when row != nil, do: nil
  defp effect(_failed, row), do: row

  defp view(base, overlay) do
    case entry(overlay) do
      :absent -> base
      :deleted -> nil
      {_kind, record} -> record.v
    end
  end

  # Ramal.Capture: the action runs on what the branch sees and its write goes in with the put of its action type
  # (capture.go in model.bend). A failed action writes nothing.
  defp capture(action, base, overlay) do
    case {action, view(base, overlay)} do
      {{:create, v}, nil} -> Overlay.put_created(overlay, @ref, %{v: v})
      {{:set, v}, row} when row != nil -> Overlay.put_updated(overlay, @ref, %{v: v})
      {{:add, n}, row} when row != nil -> Overlay.put_updated(overlay, @ref, %{v: row + n})
      {:delete, row} when row != nil -> Overlay.put_deleted(overlay, @ref)
      _failed -> overlay
    end
  end

  defp honest?(base, overlay) do
    case entry(overlay) do
      :absent -> true
      {:created, _} -> base == nil
      _updated_or_deleted -> base != nil
    end
  end

  property "a read in the branch sees the row the merge's replay produces (law branch_reads_replay)" do
    check all(
            base <- one_of([constant(nil), integer(0..9)]),
            log <- list_of(action(), max_length: 12)
          ) do
      overlay = Enum.reduce(log, %{}, &capture(&1, base, &2))
      assert view(base, overlay) == Enum.reduce(log, base, &effect/2)
    end
  end

  property "every entry is honest about the base (law branch_honest)" do
    check all(
            base <- one_of([constant(nil), integer(0..9)]),
            log <- list_of(action(), max_length: 12)
          ) do
      Enum.reduce(log, %{}, fn action, overlay ->
        overlay = capture(action, base, overlay)
        assert honest?(base, overlay)
        overlay
      end)
    end
  end

  # The row lock of Ramal.Branch.Server.capture/3 rests on this: taking back the newest write to a row restores the
  # branch, and taking back an older one would not (it drops the newer write from the overlay but not from the log).
  property "undoing the newest write to a row restores the branch as it was before that write" do
    check all(
            writes <-
              list_of(tuple({member_of([:created, :updated, :deleted]), integer(0..9)}),
                min_length: 1
              )
          ) do
      {written, _undo} =
        Enum.reduce(writes, {Branch.new(MyApp.Farm), nil}, fn {kind, v}, {branch, _undo} ->
          Branch.put_write(
            branch,
            kind,
            @ref,
            %{v: v},
            %{fingerprint: 1, snapshot: %{v: 0}},
            log_entry(v)
          )
        end)

      {last, undo} =
        Branch.put_write(
          written,
          :updated,
          @ref,
          %{v: 10},
          %{fingerprint: 1, snapshot: %{v: 0}},
          log_entry(10)
        )

      assert Branch.undo(last, [undo]) == written
    end
  end

  defp log_entry(v),
    do: {:update, Herd, :update, %{v: v}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
end
