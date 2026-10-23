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

    # An upsert on the name; `upsert_fields` limits what an existing row takes from the input.
    create :upsert do
      accept([:name, :hectares, :capacity_head])
      upsert?(true)
      upsert_identity(:unique_name)
    end

    create :upsert_capacity do
      accept([:name, :hectares, :capacity_head])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_fields([:capacity_head])
    end

    # A condition is a filter the database evaluates against the existing row.
    create :upsert_if_larger do
      accept([:name, :capacity_head])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_condition(expr(capacity_head < upsert_conflict(:capacity_head)))
    end
  end

  identities do
    identity(:unique_name, [:name])
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

    # The first and the list of related values follow the aggregate's sort; `uniq?` counts and lists distinct values.
    first(:first_herd_name, :herds, :name, public?: true, sort: [name: :asc])
    first(:biggest_herd_name, :herds, :name, public?: true, sort: [head: :desc])
    list(:herd_names, :herds, :name, public?: true, sort: [name: :asc])
    list(:herd_sizes, :herds, :size, public?: true, sort: [name: :asc])
    list(:distinct_head_list, :herds, :head, public?: true, uniq?: true, sort: [head: :asc])
    count(:distinct_heads, :herds, field: :head, public?: true, uniq?: true)

    # A kind the preparation cannot compute over a branch: it keeps the database's value and emits the event.
    custom(:herd_name_csv, :herds, :string,
      public?: true,
      implementation: {Ramal.Test.Farm.StringAgg, field: :name, delimiter: ","}
    )
  end
end
