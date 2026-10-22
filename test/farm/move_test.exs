defmodule Ramal.Test.Farm.MoveTest do
  use Ramal.DataCase, async: false

  setup do
    {:ok, Seeds.seed!()}
  end

  test "a move is created for a herd and loads it", %{herds: herds, paddocks: paddocks} do
    move =
      Ash.create!(
        Move,
        %{
          herd_id: herds.r9.id,
          from_paddock_id: paddocks.l18.id,
          to_paddock_id: paddocks.l07.id,
          moved_on: ~D[2026-03-01]
        },
        authorize?: false
      )

    assert {:ok, _} = Ecto.UUID.cast(move.id)
    assert Ash.load!(move, :herd, authorize?: false).herd.name == "R9"
  end

  test "a move needs a herd, a destination and a date", %{paddocks: paddocks} do
    assert {:error, error} =
             Ash.create(Move, %{from_paddock_id: paddocks.l07.id}, authorize?: false)

    assert error.errors |> Enum.map(& &1.field) |> Enum.sort() == [
             :herd_id,
             :moved_on,
             :to_paddock_id
           ]
  end
end
