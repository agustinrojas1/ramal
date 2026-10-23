defmodule Ramal.Test.PgTenants do
  @moduledoc false
  # Multitenant resources on Postgres, one for each strategy, to prove a branch works in one tenant against the real
  # data layer (ADR 0033): Note keeps every tenant in one table (attribute), Plot gives each tenant a schema (context).
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.PgTenants.Note)
    resource(Ramal.Test.PgTenants.Plot)
  end
end

defmodule Ramal.Test.PgTenants.Note do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.PgTenants,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("tenant_notes")
    repo(Ramal.TestRepo)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :string, public?: true, allow_nil?: false)
    attribute(:title, :string, public?: true)
  end
end

defmodule Ramal.Test.PgTenants.Plot do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.PgTenants,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("tenant_plots")
    repo(Ramal.TestRepo)
  end

  multitenancy do
    strategy(:context)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end
end
