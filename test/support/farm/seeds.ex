defmodule Ramal.Test.Farm.Seeds do
  @moduledoc false
  # Two paddocks and three herds with known names, so a test can say what it expects by name.
  #
  #   L07 (capacity 100): R7 (30 head), R8 (35 head)
  #   L18 (capacity 60):  R9 (25 head)
  #
  # R7 fits into L18 (55), R8 alone fits (exactly 60), both together do not (90).
  alias Ramal.Test.Farm.{Herd, Paddock}

  def seed! do
    l07 =
      Ash.create!(Paddock, %{name: "L07", hectares: 40.0, capacity_head: 100}, authorize?: false)

    l18 =
      Ash.create!(Paddock, %{name: "L18", hectares: 25.5, capacity_head: 60}, authorize?: false)

    r7 = Ash.create!(Herd, %{name: "R7", head: 30, paddock_id: l07.id}, authorize?: false)
    r8 = Ash.create!(Herd, %{name: "R8", head: 35, paddock_id: l07.id}, authorize?: false)
    r9 = Ash.create!(Herd, %{name: "R9", head: 25, paddock_id: l18.id}, authorize?: false)

    %{paddocks: %{l07: l07, l18: l18}, herds: %{r7: r7, r8: r8, r9: r9}}
  end
end
