defmodule Ramal.Test.Farm.HerdVet do
  @moduledoc false
  # The join resource of Herd <-> Vet. Its primary key is the pair of foreign keys, so a branch has to key overlay
  # entries by a tuple, the case DESIGN open question 3 asked about.
  use Ash.Resource,
    domain: Ramal.Test.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("herd_vets")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    attribute(:assigned_on, :date, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :herd, Ramal.Test.Farm.Herd do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end

    belongs_to :vet, Ramal.Test.Farm.Vet do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end
  end
end
