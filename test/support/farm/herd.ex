defmodule Ramal.Test.Farm.Herd do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ramal.Test.Farm.{Move, Validations}

  postgres do
    table("herds")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    update :move do
      description(
        "Moves the herd to another paddock, refusing when the destination would exceed its capacity."
      )

      # The capacity validation reads other herds, so it cannot be expressed atomically.
      require_atomic?(false)
      accept([])

      argument(:to_paddock_id, :uuid, allow_nil?: false)

      change(set_attribute(:paddock_id, arg(:to_paddock_id)))
      validate(Validations.DestinationCapacity)

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn changeset, herd ->
          Ash.create!(
            Move,
            %{
              herd_id: herd.id,
              from_paddock_id: changeset.data.paddock_id,
              to_paddock_id: herd.paddock_id,
              moved_on: Date.utc_today()
            },
            authorize?: false
          )

          {:ok, herd}
        end)
      end)
    end

    # The three ways a host manages the many_to_many through the join resource. `:append_and_remove` unrelates the
    # missing vets with a bulk destroy on the join resource, which a branch refuses (see Ramal.ManyToManyTest).
    update :add_vets do
      require_atomic?(false)
      accept([:head])

      argument(:vet_ids, {:array, :uuid}, allow_nil?: false)

      change(manage_relationship(:vet_ids, :vets, type: :append))
    end

    update :drop_vets do
      require_atomic?(false)
      accept([:head])

      argument(:vet_ids, {:array, :uuid}, allow_nil?: false)

      change(manage_relationship(:vet_ids, :vets, type: :remove))
    end

    update :set_vets do
      require_atomic?(false)
      accept([:head])

      argument(:vet_ids, {:array, :uuid}, allow_nil?: false)

      change(manage_relationship(:vet_ids, :vets, type: :append_and_remove))
    end
  end

  policies do
    policy action(:move) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end

    policy action([:read, :create, :update, :destroy]) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:head, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  calculations do
    # An expression calculation: the data layer computes it in SQL, and Ash can evaluate it on a record in memory.
    calculate(:size, :string, expr(if head >= 30, do: "large", else: "small"), public?: true)
  end

  relationships do
    belongs_to(:paddock, Ramal.Test.Farm.Paddock, public?: true, attribute_writable?: true)
    has_many(:moves, Ramal.Test.Farm.Move, public?: true)

    many_to_many :vets, Ramal.Test.Farm.Vet do
      through(Ramal.Test.Farm.HerdVet)
      source_attribute_on_join_resource(:herd_id)
      destination_attribute_on_join_resource(:vet_id)
      public?(true)
    end
  end
end
