defmodule Ramal.ThroughTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  #
  # `Paddock.herd_moves` is `has_many :herd_moves, Move, through: [:herds, :moves]`. AshPostgres loads it with one
  # lateral join over the herds and moves tables, which never sees the branch's rows (ADR 0046).
  use Ramal.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias Ramal.Test.Farm.{HerdVet, Vet}

  # Moves are told apart by their day. L07 holds R7 (days 1 and 2) and R8 (day 3); L18 holds R9 (day 4).
  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    h = seeds.herds
    moves = for {herd, day} <- [{h.r7, 1}, {h.r7, 2}, {h.r8, 3}, {h.r9, 4}], do: move!(herd, day)

    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch, moves: moves})}
  end

  defp move!(herd, day) do
    Ash.create!(
      Move,
      %{
        herd_id: herd.id,
        to_paddock_id: herd.paddock_id,
        moved_on: Date.new!(2026, 1, day)
      },
      authorize?: false
    )
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  # The days of each paddock's moves, as %{paddock name => [day]}.
  defp days(opts \\ []) do
    load = Keyword.get(opts, :load, :herd_moves)

    Paddock
    |> Ash.Query.load(load)
    |> Ash.read!(Keyword.drop(opts, [:load]) ++ [authorize?: false])
    |> Map.new(&{&1.name, &1 |> Map.fetch!(:herd_moves) |> day_list()})
  end

  defp day_list(moves), do: moves |> Enum.map(& &1.moved_on.day) |> Enum.sort()

  describe "a through path of several hops" do
    test "outside a branch the database answers" do
      assert days() == %{"L07" => [1, 2, 3], "L18" => [4]}
    end

    test "a branch that changed nothing on the path leaves the load alone", %{branch: branch} do
      assert inside(branch, fn -> days() end) == %{"L07" => [1, 2, 3], "L18" => [4]}
    end

    test "a branch that changed only the sources leaves the load alone", %{
      branch: branch,
      paddocks: p
    } do
      inside(branch, fn ->
        Ash.update!(p.l07, %{name: "L07b"}, authorize?: false)
        assert days() == %{"L07b" => [1, 2, 3], "L18" => [4]}
      end)
    end

    test "a move created in the branch joins its herd's paddock", %{branch: branch, herds: h} do
      inside(branch, fn ->
        move!(h.r9, 5)
        move!(h.r7, 6)
        assert days() == %{"L07" => [1, 2, 3, 6], "L18" => [4, 5]}
      end)

      assert days() == %{"L07" => [1, 2, 3], "L18" => [4]}
    end

    test "a move given to another herd leaves one paddock and joins the other", %{
      branch: branch,
      herds: h,
      moves: [m1 | _]
    } do
      inside(branch, fn ->
        Ash.update!(m1, %{herd_id: h.r9.id}, authorize?: false)
        assert days() == %{"L07" => [2, 3], "L18" => [1, 4]}
      end)
    end

    test "a herd moved to another paddock takes its moves along", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      inside(branch, fn ->
        Ash.update!(h.r7, %{paddock_id: p.l18.id}, authorize?: false)
        assert days() == %{"L07" => [3], "L18" => [1, 2, 4]}
      end)
    end

    test "a herd destroyed in the branch takes its moves with it", %{branch: branch, herds: h} do
      inside(branch, fn ->
        Ash.destroy!(h.r7, authorize?: false)
        assert days() == %{"L07" => [3], "L18" => [4]}
      end)
    end

    test "a move destroyed in the branch disappears", %{branch: branch, moves: [_, m2 | _]} do
      inside(branch, fn ->
        Ash.destroy!(m2, authorize?: false)
        assert days() == %{"L07" => [1, 3], "L18" => [4]}
      end)
    end

    test "a herd and a move created in the branch reach a paddock created in it", %{
      branch: branch
    } do
      inside(branch, fn ->
        paddock =
          Ash.create!(Paddock, %{name: "L99", capacity_head: 10}, authorize?: false)

        herd =
          Ash.create!(Herd, %{name: "N1", head: 1, paddock_id: paddock.id}, authorize?: false)

        move!(herd, 9)
        assert days() == %{"L07" => [1, 2, 3], "L18" => [4], "L99" => [9]}
      end)
    end

    test "a move reached through two herds of one paddock is returned once", %{
      branch: branch,
      herds: h,
      paddocks: p
    } do
      inside(branch, fn ->
        Ash.update!(h.r9, %{paddock_id: p.l07.id}, authorize?: false)
        assert days() == %{"L07" => [1, 2, 3, 4], "L18" => []}
      end)
    end

    test "the branch's rows are seen when the load is authorized", %{branch: branch, herds: h} do
      inside(branch, fn ->
        move!(h.r9, 5)

        result =
          Paddock
          |> Ash.Query.load(:herd_moves)
          |> Ash.read!(actor: %{role: :admin}, authorize?: true)

        assert Map.new(result, &{&1.name, day_list(&1.herd_moves)}) ==
                 %{"L07" => [1, 2, 3], "L18" => [4, 5]}
      end)
    end

    test "a load of a single record sees the branch", %{branch: branch, herds: h, paddocks: p} do
      inside(branch, fn ->
        move!(h.r9, 5)
        paddock = Ash.get!(Paddock, p.l18.id, load: :herd_moves, authorize?: false)
        assert day_list(paddock.herd_moves) == [4, 5]
      end)
    end

    test "after the merge the database gives what the branch showed", %{
      branch: branch,
      herds: h,
      paddocks: p,
      moves: [m1, _, m3, _]
    } do
      shown =
        inside(branch, fn ->
          move!(h.r9, 5)
          Ash.update!(m1, %{herd_id: h.r9.id}, authorize?: false)
          Ash.destroy!(m3, authorize?: false)
          Ash.update!(h.r8, %{paddock_id: p.l18.id}, authorize?: false)
          days()
        end)

      assert shown == %{"L07" => [2], "L18" => [1, 4, 5]}
      assert days() == %{"L07" => [1, 2, 3], "L18" => [4]}
      assert {:ok, _} = Ramal.merge(branch)
      assert days() == shown
    end
  end

  describe "a through path loaded with a limit, an offset or a page" do
    test "a limit applies per source", %{branch: branch, herds: h} do
      inside(branch, fn ->
        move!(h.r9, 5)
        move!(h.r9, 6)
        moves = Move |> Ash.Query.sort(:moved_on) |> Ash.Query.limit(2)

        result =
          Paddock
          |> Ash.Query.load(herd_moves: moves)
          |> Ash.read!(authorize?: false)
          |> Map.new(&{&1.name, Enum.map(&1.herd_moves, fn m -> m.moved_on.day end)})

        assert result == %{"L07" => [1, 2], "L18" => [4, 5]}
      end)
    end

    test "an offset applies per source", %{branch: branch, herds: h} do
      inside(branch, fn ->
        move!(h.r9, 5)
        moves = Move |> Ash.Query.sort(:moved_on) |> Ash.Query.offset(1)

        result =
          Paddock
          |> Ash.Query.load(herd_moves: moves)
          |> Ash.read!(authorize?: false)
          |> Map.new(&{&1.name, Enum.map(&1.herd_moves, fn m -> m.moved_on.day end)})

        assert result == %{"L07" => [2, 3], "L18" => [5]}
      end)
    end

    # Ash reads the whole list for a `through` path and ignores `page:` (the relationship comes back as a list, not a
    # page), with or without a branch, so the branch must not page it either.
    test "a page option is ignored, as outside a branch", %{branch: branch, herds: h} do
      moves =
        Move |> Ash.Query.for_read(:list) |> Ash.Query.sort(:moved_on) |> Ash.Query.page(limit: 1)

      load = fn ->
        Paddock
        |> Ash.Query.load(herd_moves: moves)
        |> Ash.read!(authorize?: false)
        |> Map.new(&{&1.name, day_list(&1.herd_moves)})
      end

      assert load.() == %{"L07" => [1, 2, 3], "L18" => [4]}

      inside(branch, fn ->
        move!(h.r9, 5)
        assert load.() == %{"L07" => [1, 2, 3], "L18" => [4, 5]}
      end)
    end
  end

  describe "a through path with a many_to_many hop" do
    # AshPostgres 2.15 joins `vets` to `herds` on `herds.id = vets.id` and ignores the join resource, so the path is empty
    # whatever the data: the load is left to the database, in a branch and out of it (ADR 0046).
    setup %{herds: h} do
      ana = Ash.create!(Vet, %{name: "Ana"}, authorize?: false)
      Ash.create!(HerdVet, %{herd_id: h.r7.id, vet_id: ana.id}, authorize?: false)
      :ok
    end

    test "is empty outside a branch although the herd has a vet", %{herds: h} do
      assert Ash.load!(h.r7, :vets, authorize?: false).vets != []

      paddocks = Ash.read!(Paddock, authorize?: false) |> Ash.load!(:herd_vets, authorize?: false)
      assert Enum.all?(paddocks, &(&1.herd_vets == []))
    end

    test "is left to the database inside a branch", %{branch: branch, herds: h} do
      inside(branch, fn ->
        Ash.update!(h.r7, %{name: "R7b"}, authorize?: false)

        paddocks =
          Ash.read!(Paddock, authorize?: false) |> Ash.load!(:herd_vets, authorize?: false)

        assert Enum.all?(paddocks, &(&1.herd_vets == []))
      end)
    end
  end

  # Whatever the branch does to herds and moves, the moves a paddock loads are those whose herd is in that paddock, read
  # through the branch.
  describe "properties" do
    defp operation do
      one_of([
        tuple({constant(:create_herd), integer(0..1)}),
        tuple({constant(:create_move), integer(0..20)}),
        tuple({constant(:move_herd), integer(0..20), integer(0..1)}),
        tuple({constant(:rehome_move), integer(0..20), integer(0..20)}),
        tuple({constant(:destroy_move), integer(0..20)}),
        tuple({constant(:destroy_herd), integer(0..20)})
      ])
    end

    defp pick(list, index), do: Enum.at(list, rem(index, length(list)))

    defp apply_operation({:create_herd, paddock}, ctx) do
      paddock_id = pick(ctx.paddocks, paddock).id

      Ash.create!(
        Herd,
        %{name: "P#{System.unique_integer([:positive])}", head: 1, paddock_id: paddock_id},
        authorize?: false
      )
    end

    defp apply_operation({:create_move, herd}, _ctx) do
      case Ash.read!(Herd, authorize?: false) do
        [] ->
          :ok

        herds ->
          move!(pick(herds, herd), System.unique_integer([:positive]) |> rem(27) |> Kernel.+(1))
      end
    end

    defp apply_operation({:move_herd, herd, paddock}, ctx) do
      case Ash.read!(Herd, authorize?: false) do
        [] ->
          :ok

        herds ->
          Ash.update!(pick(herds, herd), %{paddock_id: pick(ctx.paddocks, paddock).id},
            authorize?: false
          )
      end
    end

    defp apply_operation({:rehome_move, move, herd}, _ctx) do
      with [_ | _] = moves <- Ash.read!(Move, authorize?: false),
           [_ | _] = herds <- Ash.read!(Herd, authorize?: false) do
        Ash.update!(pick(moves, move), %{herd_id: pick(herds, herd).id}, authorize?: false)
      end
    end

    defp apply_operation({:destroy_move, move}, _ctx) do
      case Ash.read!(Move, authorize?: false) do
        [] -> :ok
        moves -> Ash.destroy!(pick(moves, move), authorize?: false)
      end
    end

    defp apply_operation({:destroy_herd, herd}, _ctx) do
      case Ash.read!(Herd, authorize?: false) do
        [] -> :ok
        herds -> Ash.destroy!(pick(herds, herd), authorize?: false)
      end
    end

    property "a paddock loads the moves of the herds that are in it", %{
      paddocks: paddocks
    } do
      ctx = %{paddocks: [paddocks.l07, paddocks.l18]}

      check all(operations <- list_of(operation(), max_length: 14), max_runs: 40) do
        {:ok, branch} = Ramal.branch(Farm)

        {loaded, expected} =
          inside(branch, fn ->
            Enum.each(operations, &apply_operation(&1, ctx))

            herds = Ash.read!(Herd, authorize?: false)
            moves = Ash.read!(Move, authorize?: false)

            expected =
              Map.new(Ash.read!(Paddock, authorize?: false), fn paddock ->
                herd_ids = for h <- herds, h.paddock_id == paddock.id, do: h.id
                {paddock.id, for(m <- moves, m.herd_id in herd_ids, do: m.id) |> Enum.sort()}
              end)

            loaded =
              Paddock
              |> Ash.Query.load(:herd_moves)
              |> Ash.read!(authorize?: false)
              |> Map.new(&{&1.id, &1.herd_moves |> Enum.map(fn m -> m.id end) |> Enum.sort()})

            {loaded, expected}
          end)

        assert loaded == expected
        Ramal.discard(branch)
      end
    end
  end
end
