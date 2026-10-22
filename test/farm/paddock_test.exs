defmodule Ramal.Test.Farm.PaddockTest do
  use Ramal.DataCase, async: false

  test "a paddock is created with a UUID key, its attributes and timestamps" do
    paddock =
      Ash.create!(Paddock, %{name: "L01", hectares: 12.5, capacity_head: 80}, authorize?: false)

    assert {:ok, _} = Ecto.UUID.cast(paddock.id)
    assert %{name: "L01", hectares: 12.5, capacity_head: 80} = paddock
    assert %DateTime{} = paddock.inserted_at
    assert %DateTime{} = paddock.updated_at
  end

  test "a paddock cannot be created without a name or a capacity" do
    assert {:error, error} = Ash.create(Paddock, %{hectares: 1.0}, authorize?: false)

    fields = error.errors |> Enum.map(& &1.field) |> Enum.sort()
    assert fields == [:capacity_head, :name]
  end

  test "head_count sums the head of the herds in the paddock, and is zero for an empty one" do
    %{paddocks: %{l07: l07, l18: l18}} = Seeds.seed!()
    empty = Ash.create!(Paddock, %{name: "L99", capacity_head: 10}, authorize?: false)

    counts =
      Paddock
      |> Ash.read!(load: :head_count, authorize?: false)
      |> Map.new(&{&1.name, &1.head_count})

    assert counts == %{"L07" => 65, "L18" => 25, "L99" => 0}
    assert l07.name == "L07" and l18.name == "L18" and empty.name == "L99"
  end
end
