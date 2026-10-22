defmodule RamalLive.Test.Farm do
  @moduledoc false
  # An ETS-backed domain, so the suite needs no database: the inspector only reads what `Ramal.get/1` and `Ramal.diff/1`
  # return, and those do not care what the data layer is.
  use Ash.Domain, otp_app: :ramal_live, validate_config_inclusion?: false

  resources do
    resource(RamalLive.Test.Farm.Herd)
  end
end

defmodule RamalLive.Test.Farm.Herd do
  @moduledoc false
  use Ash.Resource,
    domain: RamalLive.Test.Farm,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:head, :integer, public?: true)
    attribute(:vet_pin, :string, sensitive?: true, public?: true)
  end
end
