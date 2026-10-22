defmodule Ramal.Test.Farm.Vet do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("vets")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    many_to_many :herds, Ramal.Test.Farm.Herd do
      through(Ramal.Test.Farm.HerdVet)
      source_attribute_on_join_resource(:vet_id)
      destination_attribute_on_join_resource(:herd_id)
      public?(true)
    end
  end
end
