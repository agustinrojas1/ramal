defmodule Ramal.Test.Farm.Paddock do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Farm,
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
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:hectares, :float, public?: true)
    attribute(:capacity_head, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many(:herds, Ramal.Test.Farm.Herd, public?: true)
  end

  aggregates do
    # Computed by the database, so a branch does not see its own moves in it. A test documents that.
    sum(:head_count, :herds, :head, default: 0, public?: true)
  end
end
