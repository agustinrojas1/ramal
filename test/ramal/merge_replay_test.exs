defmodule Ramal.MergeReplayTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Merge.Result

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp moves, do: Move |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.moved_on, Date)

  defp move_herd(herd, paddock, action) do
    Ash.update!(herd, %{to_paddock_id: paddock.id}, action: action, authorize?: false)
  end

  describe "a top-level action on a row a hook created" do
    test "an update of a Move that an after_action hook created is replayed", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      move =
        inside(branch, fn ->
          move_herd(herds.r7, paddocks.l18, :move)
          [move] = Ash.read!(Move, authorize?: false)
          Ash.update!(move, %{moved_on: ~D[2026-01-01]}, authorize?: false)
        end)

      assert {:ok, %Result{replayed: 2}} =
               Ramal.merge(branch, authorize?: false, actor: %{role: :admin})

      assert [%{id: id, moved_on: ~D[2026-01-01]}] = moves()
      assert id == move.id
    end

    test "the same for a Move that a before_action hook created", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      move =
        inside(branch, fn ->
          move_herd(herds.r7, paddocks.l18, :move_early)
          [move] = Ash.read!(Move, authorize?: false)
          Ash.destroy!(move, authorize?: false)
          move
        end)

      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      assert moves() == []
      assert move.id
    end

    test "each action keeps its own hook's key when hooks run before and after the writes", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      Ash.update!(paddocks.l18, %{capacity_head: 500}, authorize?: false)

      keys =
        inside(branch, fn ->
          move_herd(herds.r7, paddocks.l18, :move_early)
          move_herd(herds.r8, paddocks.l18, :move)
          move_herd(herds.r9, paddocks.l07, :move_early)

          by_herd = Map.new(Ash.read!(Move, authorize?: false), &{&1.herd_id, &1})

          for {herd, day} <- [
                {herds.r7, ~D[2026-01-01]},
                {herds.r8, ~D[2026-01-02]},
                {herds.r9, ~D[2026-01-03]}
              ] do
            Ash.update!(by_herd[herd.id], %{moved_on: day}, authorize?: false)
          end

          Map.new(by_herd, fn {herd_id, move} -> {herd_id, move.id} end)
        end)

      assert {:ok, %Result{replayed: 6}} =
               Ramal.merge(branch, authorize?: false, actor: %{role: :admin})

      by_herd = Map.new(moves(), &{&1.herd_id, {&1.id, &1.moved_on}})

      assert by_herd == %{
               herds.r7.id => {keys[herds.r7.id], ~D[2026-01-01]},
               herds.r8.id => {keys[herds.r8.id], ~D[2026-01-02]},
               herds.r9.id => {keys[herds.r9.id], ~D[2026-01-03]}
             }
    end
  end

  describe "a key plan" do
    test "gives the planned key to the next create of its resource and then ends" do
      planned = Ash.UUID.generate()

      {first, second} =
        Ramal.Capture.with_key_plan([{Paddock, planned}], fn ->
          {Ash.create!(Paddock, %{name: "L01", hectares: 1.0, capacity_head: 1},
             authorize?: false
           ),
           Ash.create!(Paddock, %{name: "L02", hectares: 1.0, capacity_head: 1},
             authorize?: false
           )}
        end)

      assert first.id == planned
      assert second.id != planned
    end

    test "skips a create planned as :keep, an upsert that found its row, and gives the next key to the next create" do
      planned = Ash.UUID.generate()

      {first, second} =
        Ramal.Capture.with_key_plan([{Paddock, :keep}, {Paddock, planned}], fn ->
          {Ash.create!(Paddock, %{name: "L01", hectares: 1.0, capacity_head: 1},
             authorize?: false
           ),
           Ash.create!(Paddock, %{name: "L02", hectares: 1.0, capacity_head: 1},
             authorize?: false
           )}
        end)

      assert first.id != planned
      assert second.id == planned
    end

    test "is dropped by a create of another resource, which gets the key it is given" do
      planned = Ash.UUID.generate()

      {herd, paddock} =
        Ramal.Capture.with_key_plan([{Paddock, planned}], fn ->
          {Ash.create!(Herd, %{name: "R10", head: 1}, authorize?: false),
           Ash.create!(Paddock, %{name: "L01", hectares: 1.0, capacity_head: 1},
             authorize?: false
           )}
        end)

      assert herd.id != planned
      assert paddock.id != planned
    end

    test "is not left behind when the function raises" do
      assert_raise RuntimeError, fn ->
        Ramal.Capture.with_key_plan([{Paddock, Ash.UUID.generate()}], fn -> raise "boom" end)
      end

      assert Process.get(:ramal_key_plan) == nil
    end
  end

  describe "a create whose hook creates a row of the same resource" do
    for {action, hook} <- [
          create_with_twin: "after_action",
          create_with_twin_early: "before_action"
        ] do
      test "each row keeps its own key when the #{hook} hook creates the twin", %{branch: branch} do
        {herd, twin} =
          inside(branch, fn ->
            herd =
              Ash.create!(Herd, %{name: "pair", head: 3},
                action: unquote(action),
                authorize?: false
              )

            twin = Herd |> Ash.read!(authorize?: false) |> Enum.find(&(&1.name == "pair twin"))
            Ash.update!(twin, %{head: 9}, authorize?: false)
            {herd, twin}
          end)

        refute herd.id == twin.id

        assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)

        assert %{name: "pair", head: 3} = Ash.get!(Herd, herd.id, authorize?: false)
        assert %{name: "pair twin", head: 9} = Ash.get!(Herd, twin.id, authorize?: false)
      end
    end
  end

  describe "a chain of creates of the same resource, each made by the hook of the one before" do
    for {action, hook} <- [create_chain: "after_action", create_chain_early: "before_action"] do
      test "each row keeps its own key when the #{hook} hooks make the chain", %{branch: branch} do
        rows =
          inside(branch, fn ->
            Ash.create!(Herd, %{name: "c", head: 1, depth: 2},
              action: unquote(action),
              authorize?: false
            )

            for name <- ["c+", "c++"] do
              herd = Herd |> Ash.read!(authorize?: false) |> Enum.find(&(&1.name == name))
              Ash.update!(herd, %{head: 7}, authorize?: false)
            end
          end)

        assert {:ok, %Result{replayed: 3}} = Ramal.merge(branch, authorize?: false)

        for %{id: id, name: name} <- rows do
          assert %{name: ^name, head: 7} = Ash.get!(Herd, id, authorize?: false)
        end
      end
    end
  end

  describe "attributes set outside the action's input" do
    test "an attribute changed between for_update and update is set by the merge", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        herds.r7
        |> Ash.Changeset.for_update(:update, %{name: "R7b"}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:head, 99)
        |> Ash.update!()
      end)

      assert {:ok, %Result{replayed: 1}} = Ramal.merge(branch, authorize?: false)
      assert %{name: "R7b", head: 99} = Ash.get!(Herd, herds.r7.id, authorize?: false)
    end

    test "a create keeps an attribute the caller set after for_create", %{
      branch: branch
    } do
      herd =
        inside(branch, fn ->
          Herd
          |> Ash.Changeset.for_create(:create, %{name: "R10", head: 1}, authorize?: false)
          |> Ash.Changeset.force_change_attribute(:head, 5)
          |> Ash.create!()
        end)

      assert {:ok, %Result{replayed: 1}} = Ramal.merge(branch, authorize?: false)
      assert %{name: "R10", head: 5} = Ash.get!(Herd, herd.id, authorize?: false)
    end

    test "an action that sets nothing outside its input records nothing extra", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      {:ok, %{log: [{:update, Herd, :update, _params, _actor, opts, _at}]}} = Ramal.get(branch.id)

      refute Keyword.has_key?(opts, :forced)
    end
  end

  describe "bulk actions" do
    test "a bulk update whose hooks create rows keeps each record's hook key, and a later update of one is replayed",
         %{
           branch: branch,
           herds: herds,
           paddocks: paddocks
         } do
      Ash.update!(paddocks.l18, %{capacity_head: 500}, authorize?: false)

      move_ids =
        inside(branch, fn ->
          result =
            Ash.bulk_update(Herd, :move_early, %{to_paddock_id: paddocks.l18.id},
              authorize?: false,
              strategy: [:stream],
              return_errors?: true
            )

          assert result.status == :success
          moves = Ash.read!(Move, authorize?: false)
          assert length(moves) == 3

          [first | _] = Enum.sort_by(moves, & &1.herd_id)
          Ash.update!(first, %{moved_on: ~D[2026-01-01]}, authorize?: false)
          Map.new(moves, &{&1.herd_id, &1.id})
        end)

      assert {:ok, %Result{replayed: 4}} =
               Ramal.merge(branch, authorize?: false, actor: %{role: :admin})

      assert Map.new(moves(), &{&1.herd_id, &1.id}) == move_ids

      assert Map.keys(move_ids) |> Enum.sort() ==
               herds |> Map.values() |> Enum.map(& &1.id) |> Enum.sort()

      assert Enum.count(moves(), &(&1.moved_on == ~D[2026-01-01])) == 1
    end

    test "a bulk create of an action that creates a related row gives that row its branch key at merge",
         %{
           branch: branch
         } do
      result =
        inside(branch, fn ->
          Ash.bulk_create(
            [
              %{name: "B1", head: 1, paddock: %{name: "P1", hectares: 1.0, capacity_head: 1}},
              %{name: "B2", head: 1, paddock: %{name: "P2", hectares: 1.0, capacity_head: 1}}
            ],
            Herd,
            :create_with_paddock,
            authorize?: false,
            return_errors?: true,
            return_records?: true
          )
        end)

      assert result.status == :success

      branch_paddocks =
        inside(branch, fn ->
          Paddock |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.id})
        end)

      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      db = Paddock |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.id})
      assert db["P1"] == branch_paddocks["P1"]
      assert db["P2"] == branch_paddocks["P2"]
    end

    test "every record of a bulk upsert gets its own root, and the row it creates keeps its key at merge",
         %{
           branch: branch
         } do
      created =
        inside(branch, fn ->
          result =
            Ash.bulk_create(
              [
                %{name: "L07", hectares: 41.0, capacity_head: 120},
                %{name: "NEW", hectares: 5.0, capacity_head: 9}
              ],
              Paddock,
              :upsert_capacity,
              authorize?: false,
              return_errors?: true,
              return_records?: true
            )

          Enum.find(result.records, &(&1.name == "NEW"))
        end)

      {:ok, %{log: log}} = Ramal.get(branch.id)

      roots =
        Enum.map(log, fn {_type, _resource, _action, _params, _actor, opts, _at} ->
          opts[:root]
        end)

      assert length(Enum.uniq(roots)) == 2
      assert Enum.all?(roots, &is_integer/1)

      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      assert Ash.get!(Paddock, created.id, authorize?: false).name == "NEW"
    end
  end
end
