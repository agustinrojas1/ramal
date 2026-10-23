defmodule Ramal.Preparation.Aggregates do
  @moduledoc false
  # The aggregates a read loads (`load: [:head_count]` for one declared on the resource, `Ash.Query.aggregate/4` for an
  # ad hoc one) are computed by the data layer from the base rows, so a row the branch created or changed comes out of
  # the overlay without them (`Ash.NotLoaded`, #115) and a row whose related records the branch changed carries the
  # database's number. `apply/3` fixes both after the patch (ADR 0029).
  #
  # The related records are read through the patched path, `Ash.load/3` of the relationship path with the aggregate's
  # own query as the query of the last hop, so the branch's creates, updates and destroys of them, and the aggregate's
  # filter, are applied by the same preparation as any other read. `Ramal.Aggregate.compute/4`, the pure computation
  # behind `Ramal.aggregate/4`, then reduces them. Confirmed against Ash 3.37: `Ash.Query.aggregate/4` and a declared
  # aggregate both land in `query.aggregates` by the time the hooks run, with `load` set to the record field for a
  # declared one and `nil` for an ad hoc one, whose value goes in `record.aggregates` (`lib/ash/query/aggregate.ex`).
  #
  # Reading through a relationship costs a read of the related rows per patched row, where the database computes the
  # number in one query, so only the rows that need it are recomputed: every row when the branch holds entries for a
  # resource on the aggregate's path, otherwise only the ones the overlay supplied (they have no value).
  #
  # `first` and `list` are the field of the first and of every related row in the order the aggregate's sort gave them,
  # `uniq?` deduplicates a `list` and counts distinct values in a `count`, and `include_nil?` keeps the `nil`s
  # (ADR 0039). The field may also be a calculation of the related resource: it is loaded onto the related rows with the
  # query, so a row the branch changed is judged by its new values.
  #
  # What this cannot do keeps the data layer's value and emits `[:ramal, :read, :unpatched_aggregate]`: the kind
  # `custom` (a data-layer module that produces SQL), a join filter, a custom read action, a field that is neither an
  # attribute nor a calculation, a calculation field on `sum`, `min`, `max` or `avg`, and an aggregate query with a
  # limit, an offset or a distinct.

  alias Ash.Resource.Info
  alias Ramal.Aggregate
  alias Ramal.Branch.Server

  @doc """
  The names of the aggregates of `query` that cannot be computed over the branch.
  """
  @spec unsupported(Ash.Query.t()) :: [atom]
  def unsupported(query) do
    for {name, aggregate} <- query.aggregates, not supported?(query.resource, aggregate), do: name
  end

  @doc """
  Puts the branch's value of every aggregate `query` loaded on `rows`, or the data layer's for the kinds this cannot
  compute (`unsupported/1`) when the row has none.
  """
  @spec apply([struct], Ash.Query.t(), String.t()) :: {:ok, [struct]} | {:error, term}
  def apply(rows, %{aggregates: aggregates}, _id) when map_size(aggregates) == 0, do: {:ok, rows}
  def apply([], _query, _id), do: {:ok, []}

  def apply(rows, query, id) do
    Enum.reduce_while(query.aggregates, {:ok, rows}, fn {_name, aggregate}, {:ok, rows} ->
      case one(rows, query, aggregate, id) do
        {:ok, rows} -> {:cont, {:ok, rows}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp one(rows, query, aggregate, id) do
    if supported?(query.resource, aggregate) do
      with {:ok, touched?} <- touched?(query.resource, aggregate, id) do
        compute(rows, query, named_field(aggregate), touched?)
      end
    else
      load_base(rows, query, aggregate)
    end
  end

  defp compute(rows, query, aggregate, touched?) do
    todo = if touched?, do: rows, else: Enum.filter(rows, &missing?(&1, aggregate))
    do_compute(todo, rows, query, aggregate)
  rescue
    # `min` and `max` of a string ask the database for its collation (ADR 0045), which can fail like any query.
    error in Ramal.Error -> {:error, error}
  end

  defp do_compute(todo, rows, query, aggregate) do
    with [_ | _] <- todo,
         {:ok, loaded} <- Ash.load(todo, load(query.resource, aggregate), opts(query, aggregate)) do
      values = Map.new(loaded, &{key(&1, query), value(&1, aggregate, query)})
      {:ok, Enum.map(rows, &put(&1, aggregate, Map.fetch(values, key(&1, query))))}
    else
      [] -> {:ok, rows}
      {:error, _} = error -> error
    end
  end

  defp key(row, query), do: Ramal.Resource.key(query.resource, row)

  defp put(row, _aggregate, :error), do: row
  defp put(row, %{load: field}, {:ok, value}) when field != nil, do: Map.put(row, field, value)

  defp put(row, %{name: name}, {:ok, value}),
    do: %{row | aggregates: Map.put(row.aggregates || %{}, name, value)}

  defp missing?(row, %{load: field}) when field != nil,
    do: match?(%Ash.NotLoaded{}, Map.get(row, field))

  defp missing?(row, %{name: name}), do: not Map.has_key?(row.aggregates || %{}, name)

  # The nested load that reads the aggregate's related records, the aggregate's query on the last hop.
  defp load(resource, %{relationship_path: path} = aggregate) do
    destination = destination(resource, path)

    query =
      (aggregate.query || Ash.Query.new(destination))
      |> load_calculation(destination, aggregate.field)

    Enum.reduce(Enum.reverse(path), query, fn relationship, inner -> [{relationship, inner}] end)
  end

  defp opts(query, aggregate) do
    private = query.context[:private] || %{}

    authorize =
      cond do
        aggregate.authorize? == false -> [authorize?: false]
        Map.has_key?(private, :authorize?) -> [authorize?: private.authorize?]
        true -> []
      end

    [
      domain: query.domain,
      actor: private[:actor],
      tenant: query.tenant,
      reuse_values?: true,
      context: Map.take(query.context, [:shared])
    ] ++ authorize
  end

  defp value(row, %{relationship_path: path} = aggregate, query) do
    destination = destination(query.resource, path)

    related =
      path
      |> Enum.reduce([row], fn relationship, records ->
        Enum.flat_map(records, &List.wrap(Map.fetch!(&1, relationship)))
      end)
      |> counted(aggregate)

    shape = [uniq?: aggregate.uniq?, include_nil?: aggregate.include_nil?, tenant: query.tenant]

    case Aggregate.compute(aggregate.kind, aggregate.field, related, destination, shape) do
      nil -> aggregate.default_value
      value -> value
    end
  end

  # A resource aggregate over a calculation holds the calculation struct as its field; the related rows carry its value
  # under the name it is loaded as.
  defp named_field(%{field: %Ash.Query.Calculation{load: load}} = aggregate),
    do: %{aggregate | field: load}

  defp named_field(aggregate), do: aggregate

  # The field of a `first`, `list` or `count` can be a calculation, which the related read has to compute: for a row the
  # branch changed it is evaluated in memory by the preparation of that read.
  defp load_calculation(query, destination, field) when is_atom(field) and field != nil do
    if Info.calculation(destination, field), do: Ash.Query.load(query, field), else: query
  end

  defp load_calculation(query, _destination, _field), do: query

  # Ash's `count` of a field counts the rows where it is not nil, unless `include_nil?` is set.
  defp counted(records, %{kind: :count, field: field, include_nil?: false}) when field != nil,
    do: Enum.reject(records, &is_nil(Map.get(&1, field)))

  defp counted(records, _aggregate), do: records

  # A row of the overlay has no value for an aggregate this cannot compute, so the data layer's is loaded for it, which
  # is the documented base value rather than a struct (`Ash.load/3` runs the aggregate in SQL from the row's key).
  defp load_base(rows, query, aggregate) do
    case Enum.filter(rows, &missing?(&1, aggregate)) do
      [] ->
        {:ok, rows}

      missing ->
        load = %{Ash.Query.new(query.resource) | aggregates: %{aggregate.name => aggregate}}

        with {:ok, loaded} <- Ash.load(missing, load, opts(query, aggregate)) do
          by_key = Map.new(loaded, &{key(&1, query), &1})
          {:ok, Enum.map(rows, &Map.get(by_key, key(&1, query), &1))}
        end
    end
  end

  defp touched?(resource, %{relationship_path: path}, id) do
    resources =
      path
      |> relationships(resource)
      |> Enum.flat_map(&[&1.destination | List.wrap(Map.get(&1, :through))])

    Enum.reduce_while(resources, {:ok, false}, fn resource, acc ->
      case Server.overlay?(id, resource) do
        {:ok, true} -> {:halt, {:ok, true}}
        {:ok, false} -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp supported?(resource, aggregate) do
    case relationships(aggregate.relationship_path, resource) do
      [] ->
        false

      relationships ->
        destination = List.last(relationships).destination

        aggregate.kind in Aggregate.kinds() and aggregate.join_filters == %{} and
          default_read?(aggregate, destination) and is_nil(aggregate.implementation) and
          field_ok?(aggregate, destination) and query_ok?(aggregate.query)
    end
  end

  # An aggregate named in a filter or sort has the destination's primary read action filled in; a declared one that was
  # not given a `read_action` has none. Only another action is a custom one.
  defp default_read?(%{read_action: nil}, _destination), do: true

  defp default_read?(%{read_action: name}, destination),
    do: match?(%{name: ^name}, Info.primary_action(destination, :read))

  defp field_ok?(%{kind: kind, field: nil}, _destination), do: kind in [:count, :exists]

  defp field_ok?(%{field: %Ash.Query.Calculation{load: load}} = aggregate, destination)
       when load != nil,
       do: field_ok?(%{aggregate | field: load}, destination)

  defp field_ok?(%{kind: kind, field: field}, destination) when is_atom(field) do
    Info.attribute(destination, field) != nil or kind == :exists or
      (kind in [:count, :first, :list] and Info.calculation(destination, field) != nil)
  end

  defp field_ok?(_aggregate, _destination), do: false

  defp query_ok?(nil), do: true

  defp query_ok?(%Ash.Query{} = query),
    do: is_nil(query.limit) and query.offset in [nil, 0] and query.distinct in [nil, []]

  defp query_ok?(_other), do: false

  defp destination(resource, path),
    do: path |> relationships(resource) |> List.last() |> Map.fetch!(:destination)

  # The relationships along `path`, or `[]` if one is not a relationship of the resource it starts from.
  defp relationships(path, resource) do
    Enum.reduce_while(path, [], fn name, acc ->
      source = if acc == [], do: resource, else: List.last(acc).destination

      case Info.relationship(source, name) do
        nil -> {:halt, []}
        relationship -> {:cont, acc ++ [relationship]}
      end
    end)
  end
end
