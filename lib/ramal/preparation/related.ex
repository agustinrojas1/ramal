defmodule Ramal.Preparation.Related do
  @moduledoc false
  # Filters and sorts through a relationship whose resource the branch changed (ADR 0025).
  #
  # The data layer judges `paddock.name == "L07"` with a join against the base paddocks, so a herd whose paddock the
  # branch renamed is matched (or missed) by the old name. Patching only the herds the branch changed cannot repair
  # that: the herds are untouched. When the filter or sort reaches a resource the branch has entries for, the part of
  # filter that reaches it is therefore taken out of the data-layer query and evaluated in Elixir with
  # `Ash.Filter.Runtime`, whose relationship loads go through the patched reads.
  #
  # The filter is split into the conjuncts of its top-level `and` chain. A conjunct with a relationship path through a
  # changed resource (a `paddock.name == ...`, an `exists(paddock, ...)`, a calculation reading one) is removed; the
  # rest stays in the data-layer query, so Postgres still narrows the rows by them. A conjunct that is an `or` or a
  # `not` is one unit, removed whole when any of its refs is affected. Removing a conjunct only widens the candidate
  # rows, never narrows them, so no row the full filter accepts is lost. The cost is a broader base read, and an
  # in-memory check of the removed conjuncts for each base row the branch did not change.
  #
  # An aggregate in a filter or sort (`herd_count >= 2`) is one more way to reach a relationship: the data layer counts
  # the base's herds, so its ref counts as reaching every resource on the aggregate's path, and a conjunct that
  # references an aggregate over a changed resource is removed like any other. `aggregates/1` hands the aggregates of
  # the removed conjuncts to the preparation, which computes them over the branch before it evaluates the conjunct.
  #
  # Confirmed against Ash 3.37 (`lib/ash/filter/filter.ex`): `Ash.Filter.list_refs/4` returns the refs of a filter with
  # the path of an `exists(...)` prefixed to the refs inside it, and with the refs of an expression calculation when
  # asked to expand calculations. A filter that names an aggregate holds an `Ash.Query.Aggregate` as the ref's
  # attribute, and a sort on one holds it in place of the field name (`{%Ash.Query.Aggregate{}, :desc}`).

  alias Ash.Query.BooleanExpression
  alias Ash.Resource.Info
  alias Ramal.Branch.Server

  @typedoc "What `plan/2` returns when a read cannot trust the data layer's judgement."
  @type plan :: %{
          required(:full) => Ash.Filter.t() | nil,
          required(:kept) => Ash.Filter.t() | nil,
          required(:removed) => Ash.Filter.t() | nil,
          required(:select) => [atom],
          required(:sort?) => boolean,
          required(:paths) => [[atom]]
        }

  @doc """
  Whether `query` filters or sorts through a relationship whose resource the branch has entries for. The cheap check
  `Ramal.aggregate/4` uses to leave the delta path.
  """
  @spec affected?(Ash.Query.t(), String.t()) :: {:ok, boolean} | {:error, Ramal.Error.t()}
  def affected?(query, id) do
    with {:ok, plan} <- plan(query, id), do: {:ok, plan != :safe}
  end

  @doc """
  `:safe` when the data layer's filter and sort can be trusted, or the `t:plan/0`: `removed` is the filter to evaluate
  in Elixir on the base rows, `kept` what the data layer keeps, `full` the whole filter for the overlay's records, and
  `select` the attributes the Elixir check needs on a base row that selects only some.
  """
  @spec plan(Ash.Query.t(), String.t()) :: {:ok, :safe | plan} | {:error, Ramal.Error.t()}
  def plan(query, id) do
    filter_refs = refs(query.filter)
    sort_refs = Enum.flat_map(List.wrap(query.sort), &sort_refs(query.resource, &1))

    if Enum.all?(filter_refs ++ sort_refs, &(path_of(&1) == [])) do
      {:ok, :safe}
    else
      with {:ok, changed} <- changed_resources(query.resource, filter_refs ++ sort_refs, id) do
        {:ok, build(query, changed, sort_refs)}
      end
    end
  end

  defp build(query, changed, sort_refs) do
    {kept, removed} =
      query.filter
      |> conjuncts()
      |> Enum.split_with(fn expression ->
        not Enum.any?(refs(expression), &affected_ref?(&1, query.resource, changed))
      end)

    sort? = Enum.any?(sort_refs, &affected_ref?(&1, query.resource, changed))

    if removed == [] and not sort? do
      :safe
    else
      %{
        full: query.filter,
        kept: filter_of(query.filter, kept),
        removed: filter_of(query.filter, removed),
        select: selects(query.resource, Enum.flat_map(removed, &refs/1) ++ sort_refs),
        sort?: sort?,
        paths: sort_paths(query.resource, sort_refs, changed)
      }
    end
  end

  @doc """
  The aggregates a filter or a sort names on the records it is evaluated on, by name.
  """
  @spec aggregates(Ash.Filter.t() | [term] | nil) :: %{atom => Ash.Query.Aggregate.t()}
  def aggregates(sort) when is_list(sort) do
    for {%Ash.Query.Aggregate{} = aggregate, _direction} <- sort,
        into: %{},
        do: {aggregate.name, aggregate}
  end

  def aggregates(filter) do
    for %{relationship_path: [], attribute: %Ash.Query.Aggregate{} = aggregate} <- refs(filter),
        into: %{},
        do: {aggregate.name, aggregate}
  end

  @doc """
  The relationship paths `filter` reaches, as the nested loads that bring them onto a record.
  """
  @spec loads(Ash.Filter.t() | nil) :: [atom | {atom, term}]
  def loads(filter) do
    filter
    |> refs()
    |> Enum.map(& &1.relationship_path)
    |> Enum.reject(&(&1 == []))
    |> Enum.uniq()
    |> Enum.map(&nested_load/1)
  end

  @doc """
  The to-one relationship paths an expression calculation reads, when every ref in it is a plain attribute at the end of
  such a path, so that it can be evaluated on a record from the relationships loaded onto it. `:error` for a calculation
  that reads an aggregate, another calculation or a to-many relationship, or has no expression.
  """
  @spec plain_paths(Ash.Resource.t(), Ash.Query.Calculation.t()) :: {:ok, [[atom]]} | :error
  def plain_paths(resource, %Ash.Query.Calculation{} = calculation) do
    if Ash.Resource.Calculation.has_expression?(calculation.module) do
      refs =
        calculation.module
        |> Ash.Resource.Calculation.expression(calculation.opts, calculation.context)
        |> expression_refs(resource)

      if Enum.all?(refs, &plain_ref?(resource, &1)) do
        {:ok, refs |> Enum.map(& &1.relationship_path) |> Enum.reject(&(&1 == [])) |> Enum.uniq()}
      else
        :error
      end
    else
      :error
    end
  end

  defp plain_ref?(resource, %{relationship_path: path, attribute: attribute}) do
    match?(%Ash.Resource.Attribute{}, attribute) and to_one?(resource, path)
  end

  defp to_one?(_resource, []), do: true

  defp to_one?(resource, [name | rest]) do
    case Info.relationship(resource, name) do
      %{cardinality: :one, destination: destination} -> to_one?(destination, rest)
      _other -> false
    end
  end

  @doc "A relationship path as the load that reaches its end: `[:a, :b]` is `{:a, :b}`."
  @spec nested_load([atom]) :: atom | {atom, term}
  def nested_load(path) do
    [last | rest] = Enum.reverse(path)
    Enum.reduce(rest, last, fn name, acc -> {name, acc} end)
  end

  # The relationship paths of the sort that reach a changed resource, which the sort loads before it evaluates.
  defp sort_paths(resource, sort_refs, changed) do
    for ref <- sort_refs,
        ref.relationship_path != [],
        affected_ref?(ref, resource, changed),
        uniq: true,
        do: ref.relationship_path
  end

  defp conjuncts(nil), do: []
  defp conjuncts(%Ash.Filter{expression: expression}), do: conjuncts(expression)
  defp conjuncts(true), do: []

  defp conjuncts(%BooleanExpression{op: :and, left: left, right: right}),
    do: conjuncts(left) ++ conjuncts(right)

  defp conjuncts(expression), do: [expression]

  defp filter_of(_filter, []), do: nil

  defp filter_of(filter, expressions) do
    %{
      filter
      | expression: Enum.reduce(expressions, &BooleanExpression.optimized_new(:and, &2, &1))
    }
  end

  defp refs(nil), do: []
  defp refs(expression), do: Ash.Filter.list_refs(expression, false, false, true)

  defp sort_refs(resource, {%Ash.Query.Calculation{} = calculation, _direction}) do
    if Ash.Resource.Calculation.has_expression?(calculation.module) do
      calculation.module
      |> Ash.Resource.Calculation.expression(calculation.opts, calculation.context)
      |> expression_refs(resource)
    else
      []
    end
  end

  defp sort_refs(_resource, {%Ash.Query.Aggregate{} = aggregate, _direction}),
    do: [%{relationship_path: [], attribute: aggregate}]

  defp sort_refs(_resource, _other), do: []

  # The path a ref reaches: its own, followed by the aggregate's when the ref names one.
  defp path_of(%{
         relationship_path: path,
         attribute: %Ash.Query.Aggregate{relationship_path: through}
       }),
       do: path ++ through

  defp path_of(%{relationship_path: path}), do: path

  defp expression_refs(expression, resource) do
    case Ash.Filter.hydrate_refs(expression, %{
           resource: resource,
           relationship_path: [],
           public?: false
         }) do
      {:ok, hydrated} -> refs(hydrated)
      _error -> []
    end
  end

  # The resources reached by the refs' paths that the branch has entries for, as a set.
  defp changed_resources(resource, refs, id) do
    refs
    |> Enum.flat_map(&reached(resource, path_of(&1)))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn reached, {:ok, changed} ->
      case Server.overlay?(id, reached) do
        {:ok, true} -> {:cont, {:ok, MapSet.put(changed, reached)}}
        {:ok, false} -> {:cont, {:ok, changed}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp affected_ref?(ref, resource, changed),
    do: Enum.any?(reached(resource, path_of(ref)), &MapSet.member?(changed, &1))

  # Every resource a path goes through, including the join resource of a many_to_many.
  defp reached(_resource, []), do: []

  defp reached(resource, [name | rest]) do
    case Info.relationship(resource, name) do
      nil ->
        []

      relationship ->
        through = Map.get(relationship, :through)
        List.wrap(through) ++ [relationship.destination | reached(relationship.destination, rest)]
    end
  end

  # What the in-memory check of the removed conjuncts reads from a base row: the first relationship hop's source
  # attribute and every attribute at the root of the query, since a query that selects some attributes leaves the others
  # out of the row.
  defp source_attribute(resource, relationship) do
    case Info.relationship(resource, relationship) do
      %{source_attribute: attribute} -> [attribute]
      _other -> []
    end
  end

  defp selects(resource, refs) do
    refs
    |> Enum.flat_map(fn
      %{relationship_path: [], attribute: %Ash.Query.Aggregate{relationship_path: [first | _]}} ->
        source_attribute(resource, first)

      %{relationship_path: [], attribute: %{name: name}} when is_atom(name) ->
        [name]

      %{relationship_path: [first | _]} ->
        source_attribute(resource, first)

      _other ->
        []
    end)
    |> Enum.filter(&Info.attribute(resource, &1))
    |> Enum.uniq()
  end
end
