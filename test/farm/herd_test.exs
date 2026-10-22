defmodule Ramal.Test.Farm.HerdTest do
  use Ramal.DataCase, async: false

  require Ash.Query

  @admin %{role: :admin}
  @worker %{role: :worker}

  setup do
    {:ok, Seeds.seed!()}
  end

  test "the seed creates two paddocks and three herds with known names", %{herds: herds} do
    assert Paddock |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort() == [
             "L07",
             "L18"
           ]

    assert Herd |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort() == [
             "R7",
             "R8",
             "R9"
           ]

    assert herds.r7.head == 30
  end

  test "a herd belongs to a paddock and loads it", %{herds: herds, paddocks: paddocks} do
    herd = Ash.load!(herds.r7, :paddock, authorize?: false)

    assert herd.paddock.id == paddocks.l07.id
  end

  test "a read can filter and sort herds", %{paddocks: paddocks} do
    names =
      Herd
      |> Ash.Query.filter(paddock_id == ^paddocks.l07.id)
      |> Ash.Query.sort(head: :desc)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.name)

    assert names == ["R8", "R7"]
  end

  test "moving a herd changes its paddock and records a Move", %{herds: herds, paddocks: paddocks} do
    moved = Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)

    assert moved.paddock_id == paddocks.l18.id
    assert [move] = Ash.read!(Move, authorize?: false)
    assert %{herd_id: herd_id, from_paddock_id: from, to_paddock_id: to} = move
    assert herd_id == herds.r7.id
    assert from == paddocks.l07.id
    assert to == paddocks.l18.id
    assert move.moved_on == Date.utc_today()
  end

  test "a move that would exceed the destination's capacity is refused and records nothing", %{
    herds: herds,
    paddocks: paddocks
  } do
    # L18 holds 60 head and already has R9 (25). R7 (30) fits; R8 (35) fits alone; both do not.
    Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)

    assert {:error, %Ash.Error.Invalid{} = error} =
             Ash.update(herds.r8, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)

    assert Exception.message(error) =~ "already has 55"
    assert [_only_the_first_move] = Ash.read!(Move, authorize?: false)
    assert Ash.get!(Herd, herds.r8.id, authorize?: false).paddock_id == paddocks.l07.id
  end

  test "a move to a destination with exactly enough room is allowed", %{
    herds: herds,
    paddocks: paddocks
  } do
    assert {:ok, _} =
             Ash.update(herds.r8, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)
  end

  test "only an admin may move a herd", %{herds: herds, paddocks: paddocks} do
    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(herds.r7, %{to_paddock_id: paddocks.l18.id},
               action: :move,
               actor: @worker
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move)

    assert Ash.read!(Move, authorize?: false) == []
  end

  test "the default actions are not restricted to admins", %{herds: herds} do
    assert {:ok, renamed} = Ash.update(herds.r7, %{name: "R7b"}, actor: @worker)
    assert renamed.name == "R7b"
  end
end
