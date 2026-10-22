defmodule Ramal.Test.Farm do
  @moduledoc false
  # The test domain. It mirrors the first real host of Ramal (an agricultural operations app).
  use Ash.Domain, otp_app: :ramal

  resources do
    resource(Ramal.Test.Farm.Paddock)
    resource(Ramal.Test.Farm.Herd)
    resource(Ramal.Test.Farm.Move)
  end
end
