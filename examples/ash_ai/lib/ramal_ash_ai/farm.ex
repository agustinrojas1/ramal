defmodule RamalAshAiExample.Farm do
  @moduledoc """
  A one-resource domain whose actions are exposed as AshAi tools.

  The data layer is ETS so that the suite needs no database; Ramal does not care which data layer a resource has.
  """
  use Ash.Domain, otp_app: :ramal_ash_ai_example, extensions: [AshAi]

  tools do
    tool(:list_herds, RamalAshAiExample.Herd, :read)
    tool(:move_herd, RamalAshAiExample.Herd, :move_herd)

    # AshAi's own `update` tool: a bulk update on a `limit(1)` query, which a branch runs record by record.
    tool(:update_herd, RamalAshAiExample.Herd, :move)
  end

  resources do
    resource(RamalAshAiExample.Herd)
  end
end
