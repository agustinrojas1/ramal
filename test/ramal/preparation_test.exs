defmodule Ramal.PreparationTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ash.Filter.Runtime
  alias Ramal.{Branch.Server, Overlay}
  alias Ramal.Test.Farm.{HerdVet, Vet}
  alias Ramal.Test.Plain

  doctest Ramal.Resource

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp put(branch, kind, record) do
    ref = {record.__struct__, Ramal.Resource.key(record.__struct__, record)}

    {:ok, _} =
      Server.update(branch.id, fn b ->
        overlay =
          case kind do
            :created -> Overlay.put_created(b.overlay, ref, record)
            :updated -> Overlay.put_updated(b.overlay, ref, record)
            :deleted -> Overlay.put_deleted(b.overlay, ref)
          end

        %{b | overlay: overlay}
      end)

    record
  end

  defp new_herd(attrs) do
    struct(Herd, Map.merge(%{id: Ash.UUID.generate(), head: 10}, Map.new(attrs)))
  end

  defp names(herds), do: Enum.map(herds, & &1.name)

  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  describe "outside a branch" do
    test "the preparation is transparent: the same reads return the same rows as a resource without the extension" do
      queries = [
        & &1,
        &Ash.Query.filter(&1, head > 26),
        &Ash.Query.sort(&1, name: :desc),
        &(&1 |> Ash.Query.sort(:name) |> Ash.Query.limit(2) |> Ash.Query.offset(1)),
        &Ash.Query.select(&1, [:name])
      ]

      for build <- queries do
        with_ext = Herd |> build.() |> Ash.read!(authorize?: false) |> Enum.map(&attrs/1)
        without = Plain.Herd |> build.() |> Ash.read!() |> Enum.map(&attrs/1)
        assert with_ext == without
      end
    end

    test "a resource that sets branchable? false is not patched even inside a branch", %{
      branch: branch
    } do
      refute Ramal.Resource.branchable?(Plain.Excluded)
      refute Ramal.Resource.branchable?(Plain.Herd)
      assert Ramal.Resource.branchable?(Herd)

      put(branch, :deleted, new_herd(id: Ash.UUID.generate(), name: "x"))
      assert [_, _, _] = inside(branch, fn -> Ash.read!(Plain.Excluded) end)
    end

    test "branchable_resources/1 lists the resources of the domain that opted in" do
      assert Enum.sort(Ramal.Resource.branchable_resources(Farm)) == [
               Herd,
               HerdVet,
               Move,
               Paddock,
               Vet
             ]

      assert Ramal.Resource.branchable_resources(Plain) == []
    end
  end

  # The two resources are different modules, so NotLoaded markers (which name their resource) are compared by field.
  defp attrs(record) do
    record
    |> Map.take([:id, :name, :head, :paddock_id])
    |> Map.new(fn
      {key, %Ash.NotLoaded{}} -> {key, :not_loaded}
      pair -> pair
    end)
  end

  describe "inside a branch" do
    test "a read sees rows created in the branch that match its filter and not the others", %{
      branch: branch,
      paddocks: p
    } do
      put(branch, :created, new_herd(name: "R10", head: 50, paddock_id: p.l18.id))
      put(branch, :created, new_herd(name: "R11", head: 5, paddock_id: p.l18.id))

      assert inside(branch, fn ->
               Herd |> Ash.Query.filter(head > 40) |> Ash.read!(authorize?: false)
             end)
             |> names() == ["R10"]

      assert inside(branch, fn ->
               Herd |> Ash.Query.sort(:name) |> Ash.read!(authorize?: false)
             end)
             |> names() == ["R10", "R11", "R7", "R8", "R9"]

      assert names(Ash.read!(Herd, authorize?: false)) |> Enum.sort() == ["R7", "R8", "R9"]
    end

    test "loading a calculation evaluates it on the rows the branch created or changed", %{
      branch: branch,
      herds: h
    } do
      put(branch, :updated, %{h.r7 | head: 5})
      put(branch, :created, new_herd(name: "N1", head: 50))

      sizes =
        inside(branch, fn ->
          Herd
          |> Ash.Query.load(:size)
          |> Ash.Query.sort(:name)
          |> Ash.read!(authorize?: false)
        end)
        |> Map.new(&{&1.name, &1.size})

      # R7 shrank in the branch, N1 exists only there, R8 and R9 are the database's own.
      assert sizes == %{"N1" => "large", "R7" => "small", "R8" => "large", "R9" => "small"}
    end

    test "a calculation with its own module is evaluated on the rows the branch created or changed",
         %{
           branch: branch,
           herds: h
         } do
      put(branch, :updated, %{h.r7 | head: 5, name: "r7x"})
      n1 = put(branch, :created, new_herd(name: "N1", head: 50))

      inside(branch, fn ->
        rows = Ash.read!(Herd, load: [:doubled, :shouted], authorize?: false)

        assert rows |> Map.new(&{&1.name, {&1.doubled, &1.shouted}}) == %{
                 "N1" => {100, "N1"},
                 "r7x" => {10, "R7X"},
                 "R8" => {h.r8.head * 2, "R8"},
                 "R9" => {h.r9.head * 2, "R9"}
               }

        assert Ash.get!(Herd, n1.id, load: [:doubled], authorize?: false).doubled == 100

        # Filtering and sorting by the module calculation judge the branch's values too.
        assert Herd
               |> Ash.Query.filter(doubled > 50)
               |> Ash.Query.sort(doubled: :desc)
               |> Ash.Query.load(:doubled)
               |> Ash.read!(authorize?: false)
               |> Enum.map(&{&1.name, &1.doubled}) ==
                 Enum.sort_by(
                   [{"N1", 100}, {"R8", h.r8.head * 2}, {"R9", h.r9.head * 2}]
                   |> Enum.filter(fn {_name, d} -> d > 50 end),
                   &elem(&1, 1),
                   :desc
                 )
      end)
    end

    # The patched list is sorted in Elixir, where strings compare as bytes, so the preparation orders text by the rank
    # the database gives it (ADR 0045, which supersedes ADR 0024). The cases are in test/ramal/collation_test.exs.
    test "a text sort over a resource the branch touched follows the database's order", %{
      branch: branch
    } do
      Enum.each(["apple", "Banana", "cherry", "Date"], fn name ->
        Ash.create!(Paddock, %{name: name, capacity_head: 1}, authorize?: false)
      end)

      names =
        inside(branch, fn ->
          Ash.create!(Paddock, %{name: "zzz", capacity_head: 1}, authorize?: false)

          Paddock
          |> Ash.Query.sort(name: :asc)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.name)
        end)

      %{rows: rows} =
        TestRepo.query!(
          "SELECT name FROM paddocks WHERE name IN ('apple', 'Banana', 'cherry', 'Date') ORDER BY name"
        )

      in_database = List.flatten(rows) ++ ["zzz"]

      assert Enum.filter(names, &(&1 in ["apple", "Banana", "cherry", "Date", "zzz"])) ==
               in_database
    end

    test "a calculation loaded by the read action's own preparation is evaluated on the branch's rows",
         %{
           branch: branch,
           herds: h
         } do
      put(branch, :updated, %{h.r7 | head: 5})
      put(branch, :created, new_herd(name: "N1", head: 50))

      sizes =
        inside(branch, fn ->
          Herd
          |> Ash.Query.for_read(:with_size, %{}, authorize?: false)
          |> Ash.read!(authorize?: false)
        end)
        |> Map.new(&{&1.name, &1.size})

      assert sizes == %{"N1" => "large", "R7" => "small", "R8" => "large", "R9" => "small"}
    end

    test "a calculation requested through read options, get or a calculation filter is also evaluated",
         %{
           branch: branch,
           herds: h
         } do
      put(branch, :updated, %{h.r7 | head: 5})
      n1 = put(branch, :created, new_herd(name: "N1", head: 50))

      inside(branch, fn ->
        by_name = Map.new(Ash.read!(Herd, load: :size, authorize?: false), &{&1.name, &1.size})
        assert %{"N1" => "large", "R7" => "small"} = by_name

        assert Ash.get!(Herd, n1.id, load: :size, authorize?: false).size == "large"
        assert Ash.get!(Herd, h.r7.id, load: :size, authorize?: false).size == "small"

        # A row that is no longer large is left out by a filter on the calculation, and the one that became large stays.
        assert Herd
               |> Ash.Query.filter(size == "large")
               |> Ash.Query.load(:size)
               |> Ash.read!(authorize?: false)
               |> Enum.map(&{&1.name, &1.size})
               |> Enum.sort() == [{"N1", "large"}, {"R8", "large"}]

        # Sorting by the calculation sees the new values too.
        assert Herd
               |> Ash.Query.sort(size: :asc, name: :asc)
               |> Ash.Query.load(:size)
               |> Ash.read!(authorize?: false)
               |> Enum.map(& &1.name) == ["N1", "R8", "R7", "R9"]
      end)
    end

    test "an updated row replaces the base row, and leaves the result when it no longer matches",
         %{
           branch: branch,
           herds: h
         } do
      put(branch, :updated, %{h.r7 | name: "R7b", head: 99})

      read = fn query ->
        inside(branch, fn -> Ash.read!(query, authorize?: false) end) |> names() |> Enum.sort()
      end

      assert read.(Ash.Query.filter(Herd, head > 90)) == ["R7b"]
      assert read.(Ash.Query.filter(Herd, head == 30)) == []
      assert read.(Ash.Query.filter(Herd, name == "R7")) == []
      assert read.(Ash.Query.filter(Herd, head < 40)) == ["R8", "R9"]
    end

    test "a filtered read agrees with filtering the unfiltered read of the same branch", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      for i <- 1..40 do
        put(branch, :created, new_herd(name: "N#{rem(i, 7)}", head: i, paddock_id: p.l18.id))
      end

      put(branch, :updated, %{h.r7 | head: 31, name: "R7b"})
      put(branch, :updated, %{h.r8 | head: 5})
      put(branch, :deleted, h.r9)

      everything = inside(branch, fn -> Ash.read!(Herd, authorize?: false) end)
      assert length(everything) == 3 + 40 - 1

      filters = [
        Ash.Query.filter(Herd, head > 20),
        Ash.Query.filter(Herd, head <= 5 or head >= 38),
        Ash.Query.filter(Herd, name == "R7b"),
        Ash.Query.filter(Herd, name != "N3" and head < 30),
        Ash.Query.filter(Herd, head not in [1, 2, 3, 31] and head < 33),
        Ash.Query.filter(Herd, head in [5, 31, 99]),
        Ash.Query.filter(Herd, contains(name, "N") and head > 10),
        Ash.Query.filter(Herd, paddock_id == ^p.l07.id),
        Ash.Query.filter(Herd, id == ^h.r9.id),
        Ash.Query.filter(Herd, id == ^h.r7.id),
        Ash.Query.filter(Herd, false)
      ]

      for query <- filters do
        {:ok, expected} =
          Runtime.filter_matches(Farm, everything, query.filter)

        read = fn query -> inside(branch, fn -> Ash.read!(query, authorize?: false) end) end

        assert read.(query) |> Enum.map(& &1.id) |> Enum.sort() ==
                 expected |> Enum.map(& &1.id) |> Enum.sort(),
               "filter #{inspect(query.filter)}"

        sorted =
          query
          |> Ash.Query.sort(head: :desc, id: :asc)
          |> Ash.Query.limit(4)
          |> Ash.Query.offset(1)

        assert read.(sorted) |> Enum.map(& &1.id) ==
                 expected
                 |> Enum.sort_by(&{-&1.head, &1.id})
                 |> Enum.drop(1)
                 |> Enum.take(4)
                 |> Enum.map(& &1.id),
               "filter #{inspect(query.filter)} sorted and paged"
      end
    end

    test "a deleted row vanishes", %{branch: branch, herds: h} do
      put(branch, :deleted, h.r8)

      assert inside(branch, fn -> Herd |> Ash.read!(authorize?: false) end)
             |> names()
             |> Enum.sort() ==
               ["R7", "R9"]
    end

    test "limit and offset apply after patching, in the query's sort order", %{
      branch: branch,
      paddocks: p
    } do
      put(branch, :created, new_herd(name: "R0", paddock_id: p.l18.id))

      read = fn limit, offset ->
        inside(branch, fn ->
          Herd
          |> Ash.Query.sort(:name)
          |> Ash.Query.limit(limit)
          |> Ash.Query.offset(offset)
          |> Ash.read!(authorize?: false)
        end)
        |> names()
      end

      assert read.(2, 0) == ["R0", "R7"]
      assert read.(2, 1) == ["R7", "R8"]
      assert read.(10, 3) == ["R9"]
    end

    test "limit takes rows from beyond the database's page when the branch deleted some", %{
      branch: branch,
      herds: h
    } do
      put(branch, :deleted, h.r7)

      herds =
        inside(branch, fn ->
          Herd |> Ash.Query.sort(:name) |> Ash.Query.limit(2) |> Ash.read!(authorize?: false)
        end)

      assert names(herds) == ["R8", "R9"]
    end

    test "overlay records honour select like base rows do", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      put(branch, :created, new_herd(name: "R10", head: 4, paddock_id: p.l18.id))
      put(branch, :updated, %{h.r7 | head: 31})

      herds =
        inside(branch, fn -> Herd |> Ash.Query.select([:name]) |> Ash.read!(authorize?: false) end)

      assert length(herds) == 4
      assert Enum.all?(herds, &match?(%Ash.NotLoaded{}, &1.head))
      assert Enum.all?(herds, &is_binary(&1.name))
    end

    test "a read of a resource the branch did not touch is paged by the database", %{
      branch: branch,
      herds: h
    } do
      put(branch, :deleted, h.r7)

      assert [_] =
               inside(branch, fn ->
                 Paddock |> Ash.Query.limit(1) |> Ash.read!(authorize?: false)
               end)
    end

    test "Ash.get finds a row created in the branch and misses a deleted one", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      created = put(branch, :created, new_herd(name: "R10", paddock_id: p.l18.id))
      put(branch, :deleted, h.r9)

      assert %{name: "R10"} =
               inside(branch, fn -> Ash.get!(Herd, created.id, authorize?: false) end)

      assert {:error, _} = inside(branch, fn -> Ash.get(Herd, h.r9.id, authorize?: false) end)
      assert %{name: "R9"} = Ash.get!(Herd, h.r9.id, authorize?: false)
    end

    test "relationship loads are patched, including the ones Ash runs in tasks", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      put(branch, :created, new_herd(name: "R10", paddock_id: p.l18.id))
      put(branch, :deleted, h.r9)
      put(branch, :updated, %{p.l07 | name: "L07b"})

      [l18] =
        inside(branch, fn ->
          Paddock
          |> Ash.Query.filter(name == "L18")
          |> Ash.Query.load(:herds)
          |> Ash.read!(authorize?: false)
        end)

      assert names(l18.herds) == ["R10"]

      [l07b] =
        inside(branch, fn ->
          Herd
          |> Ash.Query.filter(name == "R7")
          |> Ash.Query.load(:paddock)
          |> Ash.read!(authorize?: false)
        end)

      assert l07b.paddock.name == "L07b"
    end

    test "distinct keeps one row per group of the branch's view, not of the database's", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      put(branch, :created, new_herd(name: "N1", head: 40, paddock_id: p.l18.id))
      put(branch, :created, new_herd(name: "N2", head: 50, paddock_id: p.l18.id))
      put(branch, :deleted, h.r7)

      distinct = fn direction ->
        inside(branch, fn ->
          Herd
          |> Ash.Query.distinct(:paddock_id)
          |> Ash.Query.distinct_sort(head: direction)
          |> Ash.Query.sort(:name)
          |> Ash.read!(authorize?: false)
        end)
      end

      # R7 is the database's pick for L07 and is destroyed in the branch, so R8 takes its place; L18 has three herds.
      assert names(distinct.(:desc)) == ["N2", "R8"]
      assert names(distinct.(:asc)) == ["R8", "R9"]

      # Outside the branch the database answers.
      assert names(
               Herd
               |> Ash.Query.distinct(:paddock_id)
               |> Ash.Query.distinct_sort(head: :asc)
               |> Ash.Query.sort(:name)
               |> Ash.read!(authorize?: false)
             ) == ["R7", "R9"]
    end

    test "distinct on a calculation judges the branch's rows by their new values", %{
      branch: branch,
      herds: h
    } do
      # size is "large" from 30 head. R7 and R8 are the database's large herds; here one shrinks, one is destroyed, and
      # a small one is created, so the branch has a single group.
      put(branch, :updated, %{h.r7 | head: 5})
      put(branch, :deleted, h.r8)
      put(branch, :created, new_herd(name: "N1", head: 8))

      distinct = fn ->
        inside(branch, fn ->
          Herd
          |> Ash.Query.distinct(:size)
          |> Ash.Query.distinct_sort(name: :asc)
          |> Ash.Query.sort(:name)
          |> Ash.read!(authorize?: false)
        end)
      end

      assert names(distinct.()) == ["N1"]

      # Outside the branch the database answers.
      assert names(
               Herd
               |> Ash.Query.distinct(:size)
               |> Ash.Query.distinct_sort(name: :asc)
               |> Ash.Query.sort(:name)
               |> Ash.read!(authorize?: false)
             ) == ["R7", "R9"]
    end

    test "distinct on a calculation gives a group the branch created its row", %{
      branch: branch,
      herds: h
    } do
      put(branch, :deleted, h.r7)
      put(branch, :deleted, h.r8)
      put(branch, :created, new_herd(name: "N1", head: 50))
      put(branch, :created, new_herd(name: "N2", head: 8))

      herds =
        inside(branch, fn ->
          Herd
          |> Ash.Query.distinct(:size)
          |> Ash.Query.distinct_sort(head: :desc)
          |> Ash.Query.sort(:name)
          |> Ash.read!(authorize?: false)
        end)

      # R9 is bigger than N2 and N1 is the only large herd left.
      assert names(herds) == ["N1", "R9"]
    end

    test "distinct on a calculation and an attribute, with a limit and an offset", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      put(branch, :created, new_herd(name: "N1", head: 50, paddock_id: p.l18.id))
      put(branch, :created, new_herd(name: "N2", head: 1, paddock_id: p.l18.id))
      put(branch, :updated, %{h.r8 | head: 5})

      read = fn ->
        inside(branch, fn ->
          Herd
          |> Ash.Query.distinct([:size, :paddock_id])
          |> Ash.Query.distinct_sort(name: :desc)
          |> Ash.Query.sort(:name)
          |> Ash.Query.offset(1)
          |> Ash.Query.limit(2)
          |> Ash.read!(authorize?: false)
        end)
      end

      # L07: R7 large, R8 small. L18: N1 large, and R9 beats N2 (the later name) for small. Four groups, by name:
      # N1, R7, R8, R9.
      assert names(read.()) == ["R7", "R8"]
    end

    test "distinct on a calculation is transparent when the overlay does not touch the resource",
         %{
           branch: branch
         } do
      put(branch, :created, %Paddock{id: Ash.UUID.generate(), name: "L99", capacity_head: 1})

      herds =
        inside(branch, fn ->
          Herd
          |> Ash.Query.distinct(:size)
          |> Ash.Query.distinct_sort(name: :asc)
          |> Ash.Query.sort(:name)
          |> Ash.read!(authorize?: false)
        end)

      assert names(herds) == ["R7", "R9"]
    end

    test "distinct on a calculation in a query that selects some attributes judges the branch's rows",
         %{
           branch: branch,
           herds: h
         } do
      put(branch, :updated, %{h.r7 | head: 5})

      herds =
        inside(branch, fn ->
          Herd
          |> Ash.Query.select([:name])
          |> Ash.Query.distinct(:size)
          |> Ash.Query.distinct_sort(name: :asc)
          |> Ash.Query.sort(:name)
          |> Ash.read!(authorize?: false)
        end)

      # R7 shrank to "small" and R8 is the only "large" herd: the database would have picked R7 for "large".
      assert names(herds) == ["R7", "R8"]
    end

    test "Ramal.load follows the branch's foreign key, also for a record read before the move", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      {stale, moved, listed, destroyed} =
        inside(branch, fn ->
          moved = Ash.update!(h.r7, %{paddock_id: p.l18.id}, authorize?: false)
          Ash.destroy!(h.r9, authorize?: false)

          {Ramal.load!(h.r7, :paddock, authorize?: false),
           Ramal.load!(moved, :paddock, authorize?: false),
           Ramal.load!([h.r7, h.r8], :paddock, authorize?: false),
           Ramal.load!(h.r9, :paddock, authorize?: false)}
        end)

      # h.r7 was read before the move: its own paddock_id is the old one, the branch's copy is the new one.
      assert stale.paddock.name == "L18"
      assert stale.paddock_id == p.l18.id
      assert moved.paddock.name == "L18"
      assert Enum.map(listed, & &1.paddock.name) == ["L18", "L07"]
      assert destroyed.paddock.name == "L18"

      # Outside a branch it is Ash.load.
      assert Ramal.load!(h.r7, :paddock, authorize?: false).paddock.name == "L07"
      assert {:ok, %{paddock: %{name: "L07"}}} = Ramal.load(h.r7, :paddock, authorize?: false)
    end

    test "Ramal.load works with the branch passed as context", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      Ash.update!(h.r7, %{paddock_id: p.l18.id},
        authorize?: false,
        context: Ramal.context(branch)
      )

      assert Ramal.load!(h.r7, :paddock, authorize?: false, context: Ramal.context(branch)).paddock.name ==
               "L18"
    end

    test "Ash.load on records read outside the branch is patched, lazily or not", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      put(branch, :updated, %{p.l07 | name: "L07b"})
      herd = Ash.get!(Herd, h.r7.id, authorize?: false)

      for opts <- [[], [lazy?: true]] do
        loaded = inside(branch, fn -> Ash.load!(herd, :paddock, [authorize?: false] ++ opts) end)
        assert loaded.paddock.name == "L07b"
      end

      assert Ash.load!(herd, :paddock, authorize?: false).paddock.name == "L07"
    end

    # Documents a limit: Ash.load reselects the source attribute of the relationship (here paddock_id) from the data
    # layer with Ash.DataLayer.run_query, which runs none of the read hooks (deps/ash/lib/ash/actions/read/read.ex,
    # reselect_and_load/6), so the foreign key a branch changed is not seen. `reuse_values?: true` skips the reselect.
    test "Ash.load onto a record the branch moved follows the database's foreign key unless reuse_values? is set",
         %{
           branch: branch,
           herds: h,
           paddocks: p
         } do
      {moved, by_default, lazily, reusing, in_a_read} =
        inside(branch, fn ->
          moved = Ash.update!(h.r7, %{paddock_id: p.l18.id}, authorize?: false)

          {moved, Ash.load!(moved, :paddock, authorize?: false),
           Ash.load!(moved, :paddock, authorize?: false, lazy?: true),
           Ash.load!(moved, :paddock, authorize?: false, reuse_values?: true),
           Herd
           |> Ash.Query.filter(name == "R7")
           |> Ash.Query.load(:paddock)
           |> Ash.read_one!(authorize?: false)}
        end)

      assert moved.paddock_id == p.l18.id
      assert by_default.paddock.name == "L07"
      assert lazily.paddock.name == "L07"
      assert reusing.paddock.name == "L18"
      assert in_a_read.paddock.name == "L18"
      # The record itself keeps the branch's value either way.
      assert by_default.paddock_id == p.l18.id
    end

    test "reading an aggregate the preparation cannot compute emits the unpatched_aggregate event",
         %{branch: branch} do
      test = self()

      :telemetry.attach(
        "unpatched-#{inspect(test)}",
        [:ramal, :read, :unpatched_aggregate],
        fn _, _, meta, _ -> send(test, {:unpatched, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("unpatched-#{inspect(test)}") end)

      inside(branch, fn ->
        Paddock |> Ash.Query.load(:herd_name_csv) |> Ash.read!(authorize?: false)
      end)

      assert_receive {:unpatched, %{branch_id: id, resource: Paddock}} when id == branch.id

      inside(branch, fn -> Ash.read!(Paddock, authorize?: false) end)
      refute_receive {:unpatched, _}, 50
    end

    test "a patched read emits the patch event with counts", %{branch: branch, herds: h} do
      test = self()

      :telemetry.attach(
        "patch-#{inspect(test)}",
        [:ramal, :read, :patch],
        fn _, m, meta, _ -> send(test, {:patch, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("patch-#{inspect(test)}") end)

      put(branch, :deleted, h.r7)
      inside(branch, fn -> Ash.read!(Herd, authorize?: false) end)

      assert_receive {:patch, %{base_rows: 3, overlay_rows: 1, result_rows: 2, duration: _},
                      %{resource: Herd}}
    end

    test "a read in a discarded branch is refused", %{branch: branch} do
      assert :ok = Ramal.discard(branch)
      assert {:error, %Ramal.Error{reason: :not_open}} = Ramal.run(branch, fn -> :never end)
    end

    test "two branches see only their own changes", %{branch: a, herds: h} do
      {:ok, b} = Ramal.branch(Farm)
      put(a, :deleted, h.r7)

      assert length(inside(a, fn -> Ash.read!(Herd, authorize?: false) end)) == 2
      assert length(inside(b, fn -> Ash.read!(Herd, authorize?: false) end)) == 3
    end
  end
end
