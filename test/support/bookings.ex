defmodule Ramal.Test.Bookings do
  @moduledoc false
  # A domain of its own for the identity tests: the Farm domain's tests count its resources, and these identities
  # (`nils_distinct?: false`, nils distinct by default, a `where`) are not in any Farm resource. The resource is on
  # Postgres because a data layer without native identities makes Ash pre-check them with its own read, which
  # would answer for the branch and hide what Ramal checks.
  use Ash.Domain, otp_app: :ramal, validate_config_inclusion?: false

  resources do
    resource(Ramal.Test.Bookings.Booking)
  end
end

defmodule Ramal.Test.Bookings.Booking do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Bookings,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("bookings")
    identity_wheres_to_sql(unique_active_code: "active = true")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  identities do
    identity(:unique_room_day, [:room, :day], nils_distinct?: false)
    identity(:unique_tag, [:tag])

    identity(:unique_active_code, [:code],
      where: expr(active == true),
      message: "is in use by an active booking"
    )
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:room, :string, public?: true)
    attribute(:day, :integer, public?: true)
    attribute(:tag, :string, public?: true)
    attribute(:code, :string, public?: true)
    attribute(:active, :boolean, public?: true, default: true)
  end
end
