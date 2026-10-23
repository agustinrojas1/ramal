defmodule Ramal.Test.Paged do
  @moduledoc false
  # A resource whose read action requires pagination with a small default limit, as a Phoenix app often declares.
  # Ramal's own reads (the staleness check, the aggregate delta) must not come back as a page or be cut at the limit.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Paged.Item)
  end
end

defmodule Ramal.Test.Paged.Item do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Paged,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:destroy, create: :*, update: :*])

    read :read do
      primary?(true)
      pagination(required?: true, default_limit: 2, offset?: true, keyset?: true, countable: true)
    end

    # A keyset-only action, so that a page without a cursor is a keyset page.
    read :keyset do
      pagination(keyset?: true, countable: true, required?: false)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:n, :integer, public?: true)
  end
end
