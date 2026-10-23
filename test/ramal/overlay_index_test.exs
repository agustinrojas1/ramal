defmodule Ramal.OverlayIndexTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.BranchCase, async: false
  use ExUnitProperties

  alias Ramal.Test.Farm

  @herd Ramal.Test.Farm.Herd
  @paddock Ramal.Test.Farm.Paddock

  # Enough entries for the branch process to group the overlay by resource (its threshold is 5,000).
  @large 5_200

  describe "Overlay.index/1 and select_slice/3" do
    property "answer what the whole overlay answers" do
      check all(
              entries <- list_of(entry(), max_length: 40),
              resource <- member_of([@herd, @paddock, Elsewhere]),
              base_keys <- list_of(integer(1..12), max_length: 8),
              limit <- integer(0..9)
            ) do
        overlay = Map.new(entries)
        index = Overlay.index(overlay)
        possible? = fn record -> record.v <= limit end
        slice = Map.get(index, resource, %{})

        assert slice == Overlay.slice(overlay, resource)
        assert Enum.sort(Map.keys(slice)) == Enum.sort(Overlay.keys(overlay, resource))
        assert is_map_key(index, resource) == Overlay.any?(overlay, resource)

        assert Overlay.select_slice(slice, base_keys, possible?) ==
                 Overlay.select(overlay, resource, base_keys, possible?)
      end
    end

    defp entry do
      gen all(
            resource <- member_of([@herd, @paddock]),
            key <- integer(1..12),
            kind <- member_of([:created, :updated, :deleted]),
            value <- integer(0..9)
          ) do
        {{resource, key}, if(kind == :deleted, do: :deleted, else: {kind, %{id: key, v: value}})}
      end
    end

    test "leaves out a resource with no entry" do
      assert Overlay.index(%{}) == %{}
      assert Overlay.index(%{{@herd, 1} => :deleted}) == %{@herd => %{1 => :deleted}}
    end
  end

  describe "a branch process with a large overlay" do
    setup do
      {:ok, branch} = Ramal.branch(Farm)

      {:ok, _} =
        Server.update(branch.id, fn branch ->
          overlay =
            Enum.reduce(1..@large, branch.overlay, fn key, overlay ->
              Overlay.put_updated(overlay, {@herd, key}, %{id: key, v: key})
            end)

          %{branch | overlay: Overlay.put_deleted(overlay, {@paddock, 1})}
        end)

      %{id: branch.id}
    end

    # The first read of an overlay scans it, the second groups it and the third uses the groups: all must agree.
    test "answers reads the same whether it scans or uses the index", %{id: id} do
      for _ <- 1..4 do
        assert {:ok, true} = Server.overlay?(id, @herd)
        assert {:ok, false} = Server.overlay?(id, Elsewhere)
        assert {:ok, keys} = Server.keys(id, @paddock)
        assert keys == [1]
        assert {:ok, %{1 => :deleted} = paddocks} = Server.slice(id, @paddock)
        assert map_size(paddocks) == 1
        assert {:ok, herds} = Server.slice(id, @herd)
        assert map_size(herds) == @large

        # a plan for `v <= 3`: the base rows 1 and 2 are replaced and row 3 is added, the rest are ruled out
        plan = {:compare, :<=, :v, 3}
        assert {:ok, selected, @large} = Server.select(id, @herd, [1, 2, @large + 1], plan)
        assert selected |> Map.keys() |> Enum.sort() == [1, 2, 3]
      end
    end

    test "sees a write made after the index was built", %{id: id} do
      for _ <- 1..3, do: assert({:ok, true} = Server.overlay?(id, @herd))
      assert {:ok, false} = Server.overlay?(id, Elsewhere)

      {:ok, _} =
        Server.update(id, fn branch ->
          overlay = Overlay.put_created(branch.overlay, {Elsewhere, 1}, %{id: 1, v: 0})
          %{branch | overlay: Overlay.put_deleted(overlay, {@herd, 7})}
        end)

      for _ <- 1..3 do
        assert {:ok, true} = Server.overlay?(id, Elsewhere)
        assert {:ok, [1]} = Server.keys(id, Elsewhere)
      end

      assert {:ok, herds} = Server.slice(id, @herd)
      assert herds[7] == :deleted
      assert map_size(herds) == @large
    end

    test "a write between two reads does not leave a stale answer", %{id: id} do
      for round <- 1..6 do
        {:ok, _} =
          Server.update(id, fn branch ->
            %{
              branch
              | overlay:
                  Overlay.put_created(branch.overlay, {Elsewhere, round}, %{id: round, v: 0})
            }
          end)

        assert {:ok, keys} = Server.keys(id, Elsewhere)
        assert Enum.sort(keys) == Enum.to_list(1..round)
        assert {:ok, keys_again} = Server.keys(id, Elsewhere)
        assert Enum.sort(keys_again) == Enum.to_list(1..round)
      end
    end
  end
end
