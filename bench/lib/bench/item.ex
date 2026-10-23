defmodule Bench.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Bench.Item)
    resource(Bench.Note)
    resource(Bench.Row)
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

defmodule Bench.Note do
  @moduledoc false
  # A second resource that no case writes to, so that a read of it shows what a branch with a large overlay of
  # `Bench.Item` charges for a resource it did not touch.
  use Ash.Resource,
    domain: Bench.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Ramal.Resource]

  postgres do
    table("bench_notes")
    repo(Bench.Repo)
  end

  actions do
    defaults([:read, create: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, allow_nil?: false, public?: true)
  end
end
