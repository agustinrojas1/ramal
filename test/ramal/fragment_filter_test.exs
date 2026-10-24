defmodule Ramal.FragmentFilterTest do
  # A fragment is SQL text only the database can evaluate, so the runtime that judges the rows a branch holds cannot
  # (#218, ADR 0054). Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Error
  alias Ramal.Test.Customs
  alias Ramal.Test.Customs.Entry

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp names(query),
    do: query |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()

  defp big, do: Paddock |> Ash.Query.filter(fragment("? > 80", capacity_head))

  describe "a read in a branch" do
    test "sees a row the branch raised above the fragment's bound", %{branch: branch, paddocks: p} do
      before = Ramal.run!(branch, fn -> names(big()) end)

      Ramal.run!(branch, fn ->
        Ash.update!(p.l18, %{capacity_head: 500}, authorize?: false)

        assert names(big()) == Enum.sort(["L18" | before])
        assert names(Paddock |> Ash.Query.filter(capacity_head > 80)) == names(big())
      end)

      # Outside the branch the base is untouched.
      refute "L18" in names(big())
    end

    test "drops a row the branch lowered below it, and keeps one it changed but still satisfies",
         %{
           branch: branch,
           paddocks: p
         } do
      Ramal.run!(branch, fn ->
        assert "L07" in names(big())

        Ash.update!(p.l07, %{hectares: 1.0}, authorize?: false)
        assert "L07" in names(big())

        Ash.update!(p.l07, %{capacity_head: 5}, authorize?: false)
        refute "L07" in names(big())
      end)
    end

    test "sees a row the branch created and not one it destroyed", %{branch: branch, paddocks: p} do
      Ramal.run!(branch, fn ->
        Ash.create!(Paddock, %{name: "NEW", hectares: 1.0, capacity_head: 900}, authorize?: false)
        assert "NEW" in names(big())

        Ash.destroy!(p.l07, authorize?: false)
        refute "L07" in names(big())
      end)
    end

    test "judges the fragment together with the rest of the filter", %{
      branch: branch,
      paddocks: p
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l18, %{capacity_head: 500}, authorize?: false)

        both = Paddock |> Ash.Query.filter(fragment("? > 80", capacity_head) and name == "L18")
        either = Paddock |> Ash.Query.filter(fragment("? > 80", capacity_head) or name == "L07")
        negated = Paddock |> Ash.Query.filter(not fragment("? > 80", capacity_head))

        assert names(both) == ["L18"]
        assert "L18" in names(either) and "L07" in names(either)
        refute "L18" in names(negated)
      end)
    end

    test "counts, pages and aggregates by the branch's rows", %{branch: branch, paddocks: p} do
      Ramal.run!(branch, fn ->
        {:ok, base} = Ramal.aggregate(big(), :count, nil, authorize?: false)
        Ash.update!(p.l18, %{capacity_head: 500}, authorize?: false)

        assert Ramal.aggregate(big(), :count, nil, authorize?: false) == {:ok, base + 1}
        assert Ramal.aggregate(big(), :max, :capacity_head, authorize?: false) == {:ok, 500}

        page = Ash.read!(big(), page: [limit: 1, count: true], authorize?: false)
        assert page.count == base + 1
      end)
    end

    test "judges a fragment under an exists, through a resource the branch did not change", %{
      branch: branch,
      paddocks: p
    } do
      with_big_herd = Paddock |> Ash.Query.filter(exists(herds, fragment("? > 28", head)))

      Ramal.run!(branch, fn ->
        assert names(with_big_herd) == ["L07"]

        # L18's only herd (25 head) is not in the branch; its paddock is renamed, and L07 is created anew.
        Ash.update!(p.l18, %{name: "L18B"}, authorize?: false)
        Ash.create!(Paddock, %{name: "NEW", hectares: 1.0, capacity_head: 1}, authorize?: false)

        assert names(with_big_herd) == ["L07"]
      end)
    end

    test "judges a calculation whose expression holds a fragment", %{branch: branch, paddocks: p} do
      Ramal.run!(branch, fn ->
        roomy = Paddock |> Ash.Query.filter(roomy)
        assert names(roomy) == ["L07"]

        Ash.update!(p.l18, %{capacity_head: 500}, authorize?: false)
        Ash.update!(p.l07, %{capacity_head: 5}, authorize?: false)

        assert names(roomy) == ["L18"]
      end)
    end

    test "is transparent when the filter has no fragment", %{branch: branch, paddocks: p} do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l18, %{capacity_head: 500}, authorize?: false)
        assert "L18" in names(Paddock |> Ash.Query.filter(capacity_head > 80))
      end)
    end
  end

  test "assumption: a fragment is found in a filter directly, under not, in an exists and in a calculation" do
    fragment? = fn query -> Ramal.Ash.fragment?(query.filter) end

    assert fragment?.(Ash.Query.filter(Paddock, fragment("? > 80", capacity_head)))

    assert fragment?.(
             Ash.Query.filter(Paddock, name == "x" and not fragment("? > 80", capacity_head))
           )

    assert fragment?.(Ash.Query.filter(Paddock, exists(herds, fragment("? > 28", head))))
    assert fragment?.(Ash.Query.filter(Paddock, roomy))
    refute fragment?.(Ash.Query.filter(Paddock, capacity_head > 80 or name == "x"))
    refute fragment?.(Ash.Query.filter(Paddock, exists(herds, head > 28)))
  end

  test "refuses a fragment whose filter reaches a resource the branch changed", %{
    branch: branch,
    paddocks: p
  } do
    Ramal.run!(branch, fn ->
      Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)

      query = Herd |> Ash.Query.filter(fragment("? > 0", paddock.capacity_head))

      assert {:error, error} = Ash.read(query, authorize?: false)
      assert %Error{reason: :fragment_unsupported} = Error.find(error)
    end)
  end

  describe "types that are not plain scalars" do
    test "a jsonb attribute and a custom type travel to the database and back" do
      {:ok, branch} = Ramal.branch(Customs)

      Ramal.run!(branch, fn ->
        Ash.create!(Entry, %{label: "a", payload: %{"n" => 7}}, authorize?: false)
        Ash.create!(Entry, %{label: "b", payload: %{"n" => 1}}, authorize?: false)

        query = Entry |> Ash.Query.filter(fragment("(?->>'n')::int > 5", payload))
        assert query |> Ash.read!(authorize?: false) |> Enum.map(& &1.label) == ["a"]
      end)
    end
  end
end
