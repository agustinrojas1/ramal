defmodule Ramal.DeclaredAggregateTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias Ramal.Aggregate

  @loads [
    :head_count,
    :herd_count,
    :big_herd_count,
    :has_herds,
    :biggest_head,
    :average_head
  ]

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.put(seeds, :branch, branch)}
  end

  defp read_paddocks(loads \\ @loads) do
    Paddock
    |> Ash.Query.load(loads)
    |> Ash.Query.sort(:name)
    |> Ash.read!(authorize?: false)
  end

  describe "outside a branch" do
    test "declared aggregates are the database's" do
      assert [%{head_count: 65, herd_count: 2}, %{head_count: 25, herd_count: 1}] =
               read_paddocks()
    end
  end

  describe "inside a branch" do
    test "a row the branch updated keeps a number for every aggregate (#115)", %{
      branch: branch,
      paddocks: p,
      herds: h
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "L07x"}, authorize?: false)
        Ash.update!(h.r7, %{head: 1000}, authorize?: false)

        assert [
                 %{name: "L07x", head_count: 1035, herd_count: 2, biggest_head: 1000},
                 %{name: "L18", head_count: 25, herd_count: 1}
               ] = read_paddocks()
      end)
    end

    test "a paddock created in the branch has the zero values", %{branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.create!(Paddock, %{name: "New", capacity_head: 10}, authorize?: false)

        assert %{
                 head_count: 0,
                 herd_count: 0,
                 big_herd_count: 0,
                 has_herds: false,
                 biggest_head: nil,
                 average_head: nil
               } = Enum.find(read_paddocks(), &(&1.name == "New"))
      end)
    end

    test "herds created, moved and destroyed in the branch are in the paddocks' aggregates", %{
      branch: branch,
      paddocks: p,
      herds: h
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 10, paddock_id: p.l18.id}, authorize?: false)
        Ash.update!(h.r7, %{paddock_id: p.l18.id}, authorize?: false)
        Ash.destroy!(h.r8, authorize?: false)

        assert [
                 %{head_count: 0, herd_count: 0, has_herds: false, biggest_head: nil},
                 %{
                   head_count: 65,
                   herd_count: 3,
                   big_herd_count: 2,
                   has_herds: true,
                   biggest_head: 30,
                   average_head: avg
                 }
               ] = read_paddocks()

        assert_in_delta avg, 65 / 3, 1.0e-9
      end)

      assert [%{head_count: 65}, %{head_count: 25}] = read_paddocks()
    end

    test "an aggregate loaded through a relationship sees the branch", %{
      branch: branch,
      paddocks: p,
      herds: h
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(h.r9, %{head: 5}, authorize?: false)

        herd =
          Herd
          |> Ash.Query.filter(id == ^h.r9.id)
          |> Ash.Query.load(paddock: :head_count)
          |> Ash.read_one!(authorize?: false)

        assert herd.paddock.head_count == 5
        assert herd.paddock.id == p.l18.id
      end)
    end

    test "an ad hoc aggregate lands in the record's aggregates map", %{branch: branch, herds: h} do
      Ramal.run!(branch, fn ->
        Ash.update!(h.r7, %{head: 40}, authorize?: false)

        [first | _] =
          Paddock
          |> Ash.Query.aggregate(:big, :count, :herds, query: [filter: [head: [gt: 35]]])
          |> Ash.Query.sort(:name)
          |> Ash.read!(authorize?: false)

        assert first.aggregates == %{big: 1}
      end)
    end

    test "a paged read keeps the right numbers", %{branch: branch, herds: h} do
      Ramal.run!(branch, fn ->
        Ash.update!(h.r7, %{head: 1}, authorize?: false)

        assert [%{name: "L18", herd_count: 1}] =
                 Paddock
                 |> Ash.Query.load(:herd_count)
                 |> Ash.Query.sort(:name)
                 |> Ash.Query.limit(1)
                 |> Ash.Query.offset(1)
                 |> Ash.read!(authorize?: false)
      end)
    end

    test "a read with no entries for the paddocks or the herds does not recompute", %{
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        assert [%{head_count: 65}, %{head_count: 25}] = read_paddocks()
      end)
    end
  end

  describe "the unpatched_aggregate event" do
    test "is emitted for a kind the preparation cannot compute, with the database's value", %{
      branch: branch,
      paddocks: p
    } do
      test = self()
      id = "unpatched-declared-#{inspect(test)}"

      :telemetry.attach(
        id,
        [:ramal, :read, :unpatched_aggregate],
        fn _, _, meta, _ -> send(test, {:unpatched, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "L07x"}, authorize?: false)

        names = read_paddocks([:first_herd_name]) |> Enum.map(& &1.first_herd_name)
        assert names == ["R7", "R9"]
      end)

      assert_receive {:unpatched, %{branch_id: id, resource: Paddock}} when id == branch.id
    end

    test "is not emitted for the kinds it computes", %{branch: branch} do
      test = self()
      id = "patched-declared-#{inspect(test)}"

      :telemetry.attach(
        id,
        [:ramal, :read, :unpatched_aggregate],
        fn _, _, meta, _ -> send(test, {:unpatched, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      Ramal.run!(branch, fn -> read_paddocks() end)
      refute_receive {:unpatched, _}, 50
    end
  end

  # What a branch can do to herds and paddocks, as data. Indexes are taken modulo the rows alive at that point.
  defp operation do
    one_of([
      tuple({constant(:create_herd), integer(0..60), integer(-1..1)}),
      tuple({constant(:update_herd), integer(0..20), integer(0..60), integer(-1..1)}),
      tuple({constant(:destroy_herd), integer(0..20)}),
      tuple({constant(:create_paddock), constant(nil)}),
      tuple({constant(:rename_paddock), integer(0..20)}),
      tuple({constant(:destroy_paddock), integer(0..20)})
    ])
  end

  defp paddock_id(%{paddocks: []}, _p), do: nil
  defp paddock_id(_state, p) when p < 0, do: nil
  defp paddock_id(state, p), do: pick(state.paddocks, p).id

  defp pick(list, index), do: Enum.at(list, rem(index, length(list)))

  defp apply_operation({:create_herd, head, p}, state) do
    paddock_id = paddock_id(state, p)

    herd =
      Ash.create!(
        Herd,
        %{name: "H#{System.unique_integer([:positive])}", head: head, paddock_id: paddock_id},
        authorize?: false
      )

    %{state | herds: [herd | state.herds]}
  end

  defp apply_operation({:update_herd, _, _, _}, %{herds: []} = state), do: state

  defp apply_operation({:update_herd, i, head, p}, state) do
    herd = pick(state.herds, i)
    paddock_id = paddock_id(state, p)
    updated = Ash.update!(herd, %{head: head, paddock_id: paddock_id}, authorize?: false)
    %{state | herds: Enum.map(state.herds, &if(&1.id == herd.id, do: updated, else: &1))}
  end

  defp apply_operation({:destroy_herd, _}, %{herds: []} = state), do: state

  defp apply_operation({:destroy_herd, i}, state) do
    herd = pick(state.herds, i)
    Ash.destroy!(herd, authorize?: false)
    %{state | herds: Enum.reject(state.herds, &(&1.id == herd.id))}
  end

  defp apply_operation({:create_paddock, _}, state) do
    paddock =
      Ash.create!(
        Paddock,
        %{name: "N#{System.unique_integer([:positive])}", capacity_head: 100},
        authorize?: false
      )

    %{state | paddocks: [paddock | state.paddocks]}
  end

  defp apply_operation({:rename_paddock, _}, %{paddocks: []} = state), do: state

  defp apply_operation({:rename_paddock, i}, state) do
    paddock = pick(state.paddocks, i)

    updated =
      Ash.update!(paddock, %{name: "R#{System.unique_integer([:positive])}"}, authorize?: false)

    %{state | paddocks: Enum.map(state.paddocks, &if(&1.id == paddock.id, do: updated, else: &1))}
  end

  # A destroyed paddock leaves its herds behind without a paddock in the branch's view only if the database allows it,
  # so the property destroys the herds first, as a user of the branch has to.
  defp apply_operation({:destroy_paddock, _}, %{paddocks: []} = state), do: state

  defp apply_operation({:destroy_paddock, i}, state) do
    paddock = pick(state.paddocks, i)
    {inside, outside} = Enum.split_with(state.herds, &(&1.paddock_id == paddock.id))
    Enum.each(inside, &Ash.destroy!(&1, authorize?: false))
    Ash.destroy!(paddock, authorize?: false)
    %{state | herds: outside, paddocks: Enum.reject(state.paddocks, &(&1.id == paddock.id))}
  end

  property "declared aggregates equal the value computed from the branch's herds" do
    check all(operations <- list_of(operation(), max_length: 14), max_runs: 40) do
      start_branch_property(operations)
    end
  end

  defp start_branch_property(operations) do
    # Each run starts from the seeded base, which the sandbox restores between tests but not between runs.
    {:ok, branch} = Ramal.branch(Farm)
    seeds = base()

    Ramal.run!(branch, fn ->
      state =
        Enum.reduce(
          operations,
          %{herds: Map.values(seeds.herds), paddocks: Map.values(seeds.paddocks)},
          &apply_operation/2
        )

      herds = Ash.read!(Herd, authorize?: false)

      for paddock <- read_paddocks() do
        mine = Enum.filter(herds, &(&1.paddock_id == paddock.id))
        big = Enum.filter(mine, &(&1.head > 20))

        assert paddock.head_count == (Aggregate.compute(:sum, :head, mine, Herd) || 0)
        assert paddock.herd_count == length(mine)
        assert paddock.big_herd_count == length(big)
        assert paddock.has_herds == (mine != [])
        assert paddock.biggest_head == Aggregate.compute(:max, :head, mine, Herd)
        assert close?(paddock.average_head, Aggregate.compute(:avg, :head, mine, Herd))
      end

      counts =
        Map.new(read_paddocks(), fn paddock ->
          {paddock.name, Enum.count(herds, &(&1.paddock_id == paddock.id))}
        end)

      assert_filter_and_sort_match(counts)

      assert length(read_paddocks()) == length(state.paddocks)
    end)

    :ok = Ramal.discard(branch)
  end

  # A filter and a sort on the aggregate judge the same numbers a loaded one shows.
  defp assert_filter_and_sort_match(counts) do
    for minimum <- [0, 1, 2] do
      expected =
        counts
        |> Enum.filter(fn {_name, count} -> count >= minimum end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      read =
        Paddock
        |> Ash.Query.filter(herd_count >= ^minimum)
        |> Ash.Query.sort(:name)
        |> Ash.read!(authorize?: false)

      assert Enum.map(read, & &1.name) == expected
    end

    sorted =
      Paddock |> Ash.Query.sort(herd_count: :desc, name: :asc) |> Ash.read!(authorize?: false)

    assert Enum.map(sorted, & &1.name) ==
             counts
             |> Enum.sort_by(fn {name, count} -> {-count, name} end)
             |> Enum.map(&elem(&1, 0))
  end

  defp base,
    do: %{
      herds: Map.new(Ash.read!(Herd, authorize?: false), &{&1.name, &1}),
      paddocks: Map.new(Ash.read!(Paddock, authorize?: false), &{&1.name, &1})
    }

  defp close?(nil, nil), do: true
  defp close?(a, b) when is_float(a) and is_float(b), do: abs(a - b) <= 1.0e-6 * max(1.0, abs(b))
  defp close?(a, b), do: a == b
end
