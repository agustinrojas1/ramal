if Code.ensure_loaded?(Ecto.Query) do
  defmodule Ramal.Preparation.Fragments.Postgres do
    @moduledoc false
    # The Ecto half of `Ramal.Preparation.Fragments`: it needs the `Ecto.Query` macros, so it is compiled only when
    # Ecto is in the host's tree (it is with AshPostgres).

    import Ecto.Query, only: [from: 2, with_cte: 3]

    alias Ash.Resource.Info
    alias Ramal.Error

    def run(query, records, filter) do
      resource = query.resource
      table = AshPostgres.DataLayer.Info.table(resource)

      with {:ok, columns} <- columns(resource),
           ash_query = ash_query(query, filter),
           {:ok, ecto} <- Ash.Query.data_layer_query(ash_query) do
        ecto
        |> with_cte(^table, as: ^inline_table(records, columns))
        |> Ash.DataLayer.run_query(resource)
      end
    end

    defp ash_query(query, filter) do
      query.resource
      |> Ash.Query.new(domain: query.domain)
      |> Ash.Query.set_tenant(query.tenant)
      |> Ramal.Ash.do_filter(filter)
      |> Ash.Query.select(Info.primary_key(query.resource))
    end

    # The stored attributes with the SQL type a parameter of the column has (the one AshPostgres gives its own).
    defp columns(resource) do
      resource
      |> Info.attributes()
      |> Enum.reduce_while({:ok, []}, fn attribute, {:ok, columns} ->
        case AshPostgres.SqlImplementation.parameterized_type(
               attribute.type,
               attribute.constraints
             ) do
          nil -> {:halt, {:error, unsupported(resource, attribute)}}
          type -> {:cont, {:ok, [{attribute, type} | columns]}}
        end
      end)
    end

    defp unsupported(resource, attribute) do
      Error.new(
        :fragment_unsupported,
        "the #{inspect(attribute.name)} attribute of #{inspect(resource)} has a type with no SQL parameter type, so the branch's rows cannot be given to the database to evaluate a fragment",
        %{resource: resource, attribute: attribute.name}
      )
    end

    defp inline_table(records, columns) do
      types = Map.new(columns, fn {attribute, type} -> {attribute.source, type} end)
      sources = Enum.map(columns, fn {attribute, _type} -> attribute.source end)

      rows =
        for record <- records do
          Map.new(columns, fn {attribute, _type} ->
            {attribute.source, Map.fetch!(record, attribute.name)}
          end)
        end

      from(v in values(rows, types), select: map(v, ^sources))
    end
  end
end
