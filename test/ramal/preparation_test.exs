defmodule Ramal.PreparationTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

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

    test "reading an aggregate emits the unpatched_aggregate event", %{branch: branch} do
      test = self()

      :telemetry.attach(
        "unpatched-#{inspect(test)}",
        [:ramal, :read, :unpatched_aggregate],
        fn _, _, meta, _ -> send(test, {:unpatched, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("unpatched-#{inspect(test)}") end)

      inside(branch, fn ->
        Paddock |> Ash.Query.load(:head_count) |> Ash.read!(authorize?: false)
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
