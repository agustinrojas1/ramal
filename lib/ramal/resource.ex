defmodule Ramal.Resource do
  @moduledoc """
  The Spark extension that makes an Ash resource branchable.

  Add it to a resource and every read action of that resource is patched with the current branch's changes:

      defmodule MyApp.Farm.Herd do
        use Ash.Resource,
          domain: MyApp.Farm,
          data_layer: AshPostgres.DataLayer,
          extensions: [Ramal.Resource]

        # ...
      end

  A resource opts out with a `ramal` section. A table that must never be branched, such as the one Ramal stores
  branches in, should do so:

      ramal do
        branchable? false
      end

  The extension only installs hooks. They do nothing unless the calling process is inside `Ramal.run/2`, so a
  resource behaves exactly as before outside a branch.

  What the transformer installs, confirmed against the locked Ash 3.37 source:

    * a global preparation, appended with `Ash.Resource.Builder.add_preparation/3`, which Ash applies to every read
      action of the resource;
    * the write-side change arrives with write capture, issue 5 of milestone 0.1.

  ## Example

      iex> Ramal.Resource.branchable?(Ramal.Test.Farm.Herd)
      true
  """

  @ramal %Spark.Dsl.Section{
    name: :ramal,
    describe: "Controls how this resource takes part in Ramal branches.",
    schema: [
      branchable?: [
        type: :boolean,
        default: true,
        doc:
          "Whether reads of this resource are patched with a branch's changes. Set to `false` to opt out."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@ramal],
    transformers: [Ramal.Resource.Transformer]

  alias Spark.Dsl.Extension

  @doc """
  Whether `resource` uses `Ramal.Resource` and has not opted out with `branchable? false`.

  ## Example

      iex> Ramal.Resource.branchable?(Ramal.Test.Farm.Herd)
      true
  """
  @spec branchable?(module) :: boolean
  def branchable?(resource) when is_atom(resource) do
    extended?(resource) and Extension.get_opt(resource, [:ramal], :branchable?, true)
  end

  @doc """
  The resources of `domain` that are branchable.

  ## Example

      iex> Ramal.Resource.branchable_resources(Ramal.Test.Farm) |> Enum.sort()
      [Ramal.Test.Farm.Herd, Ramal.Test.Farm.Move, Ramal.Test.Farm.Paddock]
  """
  @spec branchable_resources(module) :: [module]
  def branchable_resources(domain) when is_atom(domain) do
    if Code.ensure_loaded?(domain) and function_exported?(domain, :spark_is, 0) and
         domain.spark_is() == Ash.Domain do
      domain |> Ash.Domain.Info.resources() |> Enum.filter(&branchable?/1)
    else
      []
    end
  end

  @doc """
  The overlay key of `record`: the value of its primary key attribute, or a tuple of the values for a composite key.

  ## Example

      iex> Ramal.Resource.key(Ramal.Test.Farm.Herd, %{id: "r7"})
      "r7"
  """
  @spec key(module, map) :: term
  def key(resource, record) do
    case Ash.Resource.Info.primary_key(resource) do
      [field] -> Map.fetch!(record, field)
      fields -> fields |> Enum.map(&Map.fetch!(record, &1)) |> List.to_tuple()
    end
  end

  defp extended?(resource) do
    Code.ensure_loaded?(resource) and function_exported?(resource, :spark_is, 0) and
      __MODULE__ in Spark.extensions(resource)
  end
end
