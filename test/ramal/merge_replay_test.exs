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
end
