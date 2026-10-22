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

  relationships do
    belongs_to(:paddock, Ramal.Test.Farm.Paddock, public?: true, attribute_writable?: true)
    has_many(:moves, Ramal.Test.Farm.Move, public?: true)
  end
end
