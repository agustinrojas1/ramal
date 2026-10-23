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

    # AshAi runs an `update` or `destroy` tool with `Ash.bulk_update!/4` or `Ash.bulk_destroy!/4` on a query with
    # `limit(1)` (`AshAi.Tool.Execution.run_update/7`, ash_ai 1.4.0), and a branch refuses every bulk action
    # (`:bulk_unsupported`). A generic action runs the single-record update itself, so the write is captured. The
    # request's shared context, which carries the branch, is passed on by `Ash.Scope.to_opts/1`.
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
