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
    # Computed by the database; inside a branch the preparation recomputes them from the patched rows (ADR 0029).
    sum(:head_count, :herds, :head, default: 0, public?: true)
    count(:herd_count, :herds, public?: true)
    count(:big_herd_count, :herds, public?: true, filter: expr(head > 20))
    exists(:has_herds, :herds, public?: true)
    max(:biggest_head, :herds, :head, public?: true)
    avg(:average_head, :herds, :head, public?: true)

    # A kind the preparation cannot compute over a branch: it keeps the database's value and emits the event.
    first(:first_herd_name, :herds, :name, public?: true)
  end
end
