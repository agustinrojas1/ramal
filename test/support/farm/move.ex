defmodule Ramal.Test.Farm.Move do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("moves")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:from_paddock_id, :uuid, public?: true)
    attribute(:to_paddock_id, :uuid, allow_nil?: false, public?: true)
    attribute(:moved_on, :date, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:herd, Ramal.Test.Farm.Herd, allow_nil?: false, public?: true)
  end
end
