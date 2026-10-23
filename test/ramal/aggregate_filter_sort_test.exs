defmodule Ramal.AggregateFilterSortTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.put(seeds, :branch, branch)}
  end

  # L07 has R7 and R8 and L18 has R9 in the database. In the branch R8 moves to L18, L18 gets N1, and a new paddock NP
  # gets three herds: L07 has 1, L18 has 3, NP has 3.
  defp change(p, h) do
    Ash.update!(h.r8, %{paddock_id: p.l18.id}, authorize?: false)
    Ash.create!(Herd, %{name: "N1", head: 5, paddock_id: p.l18.id}, authorize?: false)
    np = Ash.create!(Paddock, %{name: "NP", capacity_head: 9}, authorize?: false)

    for name <- ["N2", "N3", "N4"],
        do: Ash.create!(Herd, %{name: name, head: 1, paddock_id: np.id}, authorize?: false)
  end

  defp names(paddocks), do: Enum.map(paddocks, & &1.name)

  describe "a filter on an aggregate" do
    test "judges the branch's numbers, loaded or not", %{branch: branch, paddocks: p, herds: h} do
      Ramal.run!(branch, fn ->
        change(p, h)

        for load <- [[], [:herd_count]] do
          read =
            Paddock
            |> Ash.Query.filter(herd_count >= 2)
            |> Ash.Query.load(load)
            |> Ash.Query.sort(:name)
            |> Ash.read!(authorize?: false)

          assert names(read) == ["L18", "NP"]
        end

        # The database counts two herds in L07 and one in L18, so it would have answered the opposite.
        assert names(Ash.read!(Ash.Query.filter(Paddock, herd_count == 1), authorize?: false)) ==
                 ["L07"]
      end)

      assert names(Ash.read!(Ash.Query.filter(Paddock, herd_count >= 2), authorize?: false)) == [
               "L07"
             ]
    end

    test "works inside an or, with a filter in the aggregate and with other predicates", %{
      branch: branch,
      paddocks: p,
      herds: h
    } do
      Ramal.run!(branch, fn ->
        change(p, h)

        read = fn query ->
          query |> Ash.Query.sort(:name) |> Ash.read!(authorize?: false) |> names()
        end

        assert read.(Ash.Query.filter(Paddock, herd_count > 2 or name == "L07")) == [
                 "L07",
                 "L18",
                 "NP"
               ]

        assert read.(Ash.Query.filter(Paddock, herd_count > 2 and name != "NP")) == ["L18"]

        # Herds over 20 head: R7 in L07, R9 and the moved R8 in L18; the new herds are small. The database has R7 and
        # R8 in L07 and R9 in L18.
        assert read.(Ash.Query.filter(Paddock, big_herd_count == 1)) == ["L07"]
        assert read.(Ash.Query.filter(Paddock, big_herd_count == 2)) == ["L18"]
        assert read.(Ash.Query.filter(Paddock, not has_herds)) == []
      end)
    end

    test "sees a paddock created in the branch that has no herds", %{branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.create!(Paddock, %{name: "Empty", capacity_head: 1}, authorize?: false)

        assert names(Ash.read!(Ash.Query.filter(Paddock, herd_count == 0), authorize?: false)) ==
                 ["Empty"]

        assert names(Ash.read!(Ash.Query.filter(Paddock, not has_herds), authorize?: false)) == [
                 "Empty"
               ]
      end)
    end

    test "is the database's when the branch touches neither resource", %{branch: branch} do
      Ramal.run!(branch, fn ->
        read = Paddock |> Ash.Query.filter(herd_count >= 2) |> Ash.read!(authorize?: false)
        assert names(read) == ["L07"]
      end)

      assert {:ok, []} = Ramal.diff(branch)
    end
  end

  describe "a sort on an aggregate" do
    test "orders by the branch's numbers, loaded or not", %{branch: branch, paddocks: p, herds: h} do
      Ramal.run!(branch, fn ->
        change(p, h)

        for load <- [[], [:herd_count]] do
          desc =
            Paddock
            |> Ash.Query.sort(herd_count: :desc, name: :asc)
            |> Ash.Query.load(load)
            |> Ash.read!(authorize?: false)

          assert names(desc) == ["L18", "NP", "L07"]

          asc =
            Paddock
            |> Ash.Query.sort(herd_count: :asc, name: :desc)
            |> Ash.read!(authorize?: false)

          assert names(asc) == ["L07", "NP", "L18"]
        end
      end)
    end

    test "puts a paddock created in the branch where its number says, with a limit", %{
      branch: branch,
      paddocks: p,
      herds: h
    } do
      Ramal.run!(branch, fn ->
        change(p, h)

        top =
          Paddock
          |> Ash.Query.sort(herd_count: :desc, name: :desc)
          |> Ash.Query.limit(2)
          |> Ash.read!(authorize?: false)

        assert names(top) == ["NP", "L18"]
      end)
    end
  end
end
