defmodule Ramal.RelationshipNilTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Sort
  require Ash.Query

  # A herd with no paddock next to the seeded ones: Ash evaluates a sort calculation in memory only when every row in
  # the batch has the path loaded, so this one row used to make it keep the database's value for all of them.
  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    orphan = Ash.create!(Herd, %{name: "R0", head: 10}, authorize?: false)
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch, orphan: orphan})}
  end

  defp by_paddock_name(direction) do
    Herd
    |> Ash.Query.sort([{Ash.Sort.expr_sort(paddock.name, :string), direction}, name: :asc])
  end

  defp names(query), do: query |> Ash.read!(authorize?: false) |> Enum.map(& &1.name)

  describe "a sort through a relationship when a row has none" do
    # Postgres puts the null last ascending and first descending; the branch must agree.
    for {direction, expected} <- [
          asc: ["R9", "R7", "R8", "R0"],
          desc: ["R0", "R7", "R8", "R9"]
        ] do
      test "#{direction} follows the branch's rows and matches the database after the merge", %{
        branch: branch,
        paddocks: p
      } do
        direction = unquote(direction)
        expected = unquote(expected)

        # L07 becomes "ZZ", so its herds move after L18's.
        in_branch =
          Ramal.run!(branch, fn ->
            Ash.update!(p.l07, %{name: "ZZ"}, authorize?: false)
            names(by_paddock_name(direction))
          end)

        {:ok, _} = Ramal.merge(branch, authorize?: false)

        assert in_branch == names(by_paddock_name(direction))
        assert in_branch == expected
      end
    end

    test "sees a paddock the branch gave to the herd that had none", %{
      branch: branch,
      paddocks: p,
      orphan: orphan
    } do
      in_branch =
        Ramal.run!(branch, fn ->
          Ash.update!(p.l07, %{name: "ZZ"}, authorize?: false)
          Ash.update!(orphan, %{paddock_id: p.l18.id}, authorize?: false)
          names(by_paddock_name(:asc))
        end)

      {:ok, _} = Ramal.merge(branch, authorize?: false)

      assert in_branch == names(by_paddock_name(:asc))
      assert in_branch == ["R0", "R9", "R7", "R8"]
    end
  end

  test "a sort through two relationships when the second is nil on a row", %{
    branch: branch,
    paddocks: p,
    herds: h,
    orphan: orphan
  } do
    for {herd, day} <- [{h.r7, 1}, {h.r9, 2}, {orphan, 3}] do
      Ash.create!(
        Move,
        %{herd_id: herd.id, to_paddock_id: p.l07.id, moved_on: Date.new!(2026, 1, day)},
        authorize?: false
      )
    end

    sorted = fn ->
      Move
      |> Ash.Query.sort([{Ash.Sort.expr_sort(herd.paddock.name, :string), :asc}, moved_on: :asc])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.moved_on.day)
    end

    in_branch =
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "ZZ"}, authorize?: false)
        sorted.()
      end)

    {:ok, _} = Ramal.merge(branch, authorize?: false)

    assert in_branch == sorted.()
    # R9 (L18) first, then R7 (ZZ), then the herd with no paddock.
    assert in_branch == [2, 1, 3]
  end

  describe "a filter through a relationship when a row has none" do
    test "follows the branch's rows and matches the database after the merge", %{
      branch: branch,
      paddocks: p
    } do
      filters = [
        Ash.Query.filter(Herd, paddock.name == "ZZ"),
        Ash.Query.filter(Herd, paddock.name != "ZZ"),
        Ash.Query.filter(Herd, is_nil(paddock.name)),
        Ash.Query.filter(Herd, not (paddock.name == "ZZ")),
        Ash.Query.filter(Herd, paddock.name == "L07")
      ]

      in_branch =
        Ramal.run!(branch, fn ->
          Ash.update!(p.l07, %{name: "ZZ"}, authorize?: false)
          Enum.map(filters, &(&1 |> names() |> Enum.sort()))
        end)

      {:ok, _} = Ramal.merge(branch, authorize?: false)

      assert in_branch == Enum.map(filters, &(&1 |> names() |> Enum.sort()))
    end
  end
end
