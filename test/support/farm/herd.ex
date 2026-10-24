defmodule Ramal.Test.Farm.Herd do
  @moduledoc false
  use Ash.Resource,
    domain: Ramal.Test.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ramal.Test.Farm.{Checks, Move, Validations}

  postgres do
    table("herds")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    # A paginated list, as a list page declares it.
    read :list do
      pagination(
        offset?: true,
        keyset?: true,
        countable: true,
        required?: false,
        default_limit: 2
      )
    end

    # A keyset-only list, so a page can start after a cursor.
    read :keyset_list do
      pagination(keyset?: true, countable: true, required?: false)
    end

    # A read whose policy has a check that only runs on the rows the read returned (`authorize_results`).
    read :checked do
      pagination(offset?: true, countable: true, required?: false)
    end

    # An update that reads the host's context: the name takes `context[:name]` when it is given, and the returned record
    # carries `context[:request_id]` as metadata, which `Ramal.Merge.Result.entries` hands back.
    update :annotate do
      require_atomic?(false)
      accept([:head])

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.before_action(fn changeset ->
          case changeset.context[:name] do
            nil -> changeset
            name -> Ash.Changeset.force_change_attribute(changeset, :name, name)
          end
        end)
        |> Ash.Changeset.after_action(fn changeset, herd ->
          {:ok, Ash.Resource.put_metadata(herd, :request_id, changeset.context[:request_id])}
        end)
      end)
    end

    # An action that loads a calculation in its own preparation, which runs after the one Ramal installs.
    read :with_size do
      prepare(build(load: [:size]))
    end

    # A managed belongs_to on a create: Ash sets the foreign key after the before-action hooks.
    create :create_with_paddock do
      accept([:name, :head])
      argument(:paddock, :map, allow_nil?: false)
      change(manage_relationship(:paddock, type: :create))
    end

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

    # The same move with its hook before the write: the Move is created by a before_action hook, so the log holds it
    # ahead of the update that caused it.
    update :move_early do
      require_atomic?(false)
      accept([])

      argument(:to_paddock_id, :uuid, allow_nil?: false)

      change(set_attribute(:paddock_id, arg(:to_paddock_id)))

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          Ash.create!(
            Move,
            %{
              herd_id: changeset.data.id,
              from_paddock_id: changeset.data.paddock_id,
              to_paddock_id: Ash.Changeset.get_argument(changeset, :to_paddock_id),
              moved_on: Date.utc_today()
            },
            authorize?: false
          )

          changeset
        end)
      end)
    end

    # A create whose hook creates another Herd, the same resource as the action itself: the key plan of a replay (ADR
    # 0041) must give each of the two rows its own key. `:create_with_twin` writes the twin after the herd,
    # `:create_with_twin_early` before it.
    create :create_with_twin do
      accept([:name, :head])

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, herd ->
          Ash.create!(__MODULE__, %{name: herd.name <> " twin", head: 1}, authorize?: false)
          {:ok, herd}
        end)
      end)
    end

    create :create_with_twin_early do
      accept([:name, :head])

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          name = Ash.Changeset.get_attribute(changeset, :name)
          Ash.create!(__MODULE__, %{name: name <> " twin", head: 1}, authorize?: false)
          changeset
        end)
      end)
    end

    # A chain: each Herd's hook creates the next one with the same action, `depth` times. With the hook before the
    # write, the rows are written deepest first but their changesets are built outermost first.
    for {name, hook} <- [create_chain: :after_action, create_chain_early: :before_action] do
      create name do
        accept([:name, :head])
        argument(:depth, :integer, default: 0)

        change(fn changeset, context ->
          depth = Ash.Changeset.get_argument(changeset, :depth)
          action = changeset.action.name

          create_next = fn changeset ->
            if depth > 0 do
              name = Ash.Changeset.get_attribute(changeset, :name)

              Ash.create!(__MODULE__, %{name: name <> "+", head: 1, depth: depth - 1},
                action: action,
                authorize?: false
              )
            end

            :ok
          end

          case unquote(hook) do
            :before_action ->
              Ash.Changeset.before_action(changeset, fn changeset ->
                create_next.(changeset)
                changeset
              end)

            :after_action ->
              Ash.Changeset.after_action(changeset, fn changeset, herd ->
                create_next.(changeset)
                {:ok, herd}
              end)
          end
        end)
      end
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

    # A read policy filters by default; the runtime access type keeps the check for the rows (`authorize_results`).
    policy action(:checked) do
      access_type(:runtime)
      authorize_if(Checks.SmallHerd)
    end

    policy action([
             :read,
             :list,
             :keyset_list,
             :create,
             :update,
             :destroy,
             :move_early,
             :annotate
           ]) do
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

    # Calculations with their own module: one has an expression (the data layer computes it), one runs in Elixir.
    calculate(:doubled, :integer, Ramal.Test.Farm.Calculations.Doubled, public?: true)
    calculate(:shouted, :string, Ramal.Test.Farm.Calculations.Shouted, public?: true)
  end

  aggregates do
    # `from_paddock_id` can be nil, so these show what `include_nil?` keeps.
    list(:origins, :moves, :from_paddock_id, public?: true, sort: [moved_on: :asc])

    list(:origins_with_nil, :moves, :from_paddock_id,
      public?: true,
      include_nil?: true,
      sort: [moved_on: :asc]
    )

    first(:first_origin, :moves, :from_paddock_id,
      public?: true,
      include_nil?: true,
      sort: [moved_on: :asc]
    )
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
