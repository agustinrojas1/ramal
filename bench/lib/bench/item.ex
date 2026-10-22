defmodule Bench.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Bench.Item)
  end
end

defmodule Bench.Item do
  @moduledoc false
  # One plain resource: the workload is about the cost of branching, not about the shape of the data.
  use Ash.Resource,
    domain: Bench.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Ramal.Resource]

  postgres do
    table("bench_items")
    repo(Bench.Repo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:score, :integer, allow_nil?: false, public?: true)
    attribute(:bucket, :integer, allow_nil?: false, public?: true)
  end
end
