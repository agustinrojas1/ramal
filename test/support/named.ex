defmodule Ramal.Test.Named do
  @moduledoc false
  # A domain over the paddocks table whose primary key is the caller-chosen name and which declares no identity: the
  # table's unique index on `name` is the only thing that refuses a taken key, and Ash does not map it (issue #250).
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Named.NamedPaddock)
  end
end

defmodule Ramal.Test.Named.NamedPaddock do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Named,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("paddocks")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:capacity_head, :integer, allow_nil?: false, public?: true)
  end
end
