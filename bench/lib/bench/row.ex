defmodule Bench.Row do
  @moduledoc false
  # A row shaped like the ones an application has: timestamps, a foreign key, a text column, two relationships and an
  # aggregate. Bench.Item is about the cost of branching; this one is about what a branch keeps for each row it holds,
  # which grows with the width of the record (Bench.Memory).
  use Ash.Resource,
    domain: Bench.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Ramal.Resource]

  postgres do
    table("bench_rows")
    repo(Bench.Repo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:notes, :string, public?: true)
    attribute(:score, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:parent, Bench.Row, public?: true, attribute_writable?: true)
    has_many(:children, Bench.Row, destination_attribute: :parent_id, public?: true)
  end

  aggregates do
    count(:children_count, :children, public?: true)
  end
end
