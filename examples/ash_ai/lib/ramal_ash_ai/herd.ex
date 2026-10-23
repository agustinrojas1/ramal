defmodule RamalAshAiExample.Herd do
  @moduledoc """
  A herd that an agent can list and move between paddocks.
  """
  use Ash.Resource,
    domain: RamalAshAiExample.Farm,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Ramal.Resource]

  actions do
    defaults([:read, :destroy, create: :*])

    update :move do
      accept([:paddock])
    end

    # A generic action that runs the single-record update itself. AshAi's own `update` tool works in a branch too (it is
    # a bulk update that a branch runs record by record, ADR 0036); this one shows how a hand-written tool passes the
    # request's shared context, which carries the branch, on with `Ash.Scope.to_opts/1`.
    action :move_herd, :struct do
      description("Moves the herd with the given id to another paddock.")
      constraints(instance_of: __MODULE__)

      argument(:id, :uuid, allow_nil?: false)
      argument(:paddock, :string, allow_nil?: false)

      run(fn input, context ->
        opts = Ash.Scope.to_opts(context)

        __MODULE__
        |> Ash.get!(input.arguments.id, opts)
        |> Ash.Changeset.for_update(:move, %{paddock: input.arguments.paddock}, opts)
        |> Ash.update(opts)
      end)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:paddock, :string, allow_nil?: false, public?: true)
  end
end
