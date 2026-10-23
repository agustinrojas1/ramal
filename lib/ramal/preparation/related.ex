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
  # Confirmed against Ash 3.37 (`lib/ash/filter/filter.ex`): `Ash.Filter.list_refs/4` returns the refs of a filter with
  # the path of an `exists(...)` prefixed to the refs inside it, and with the refs of an expression calculation when
  # asked to expand calculations.

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

    if Enum.all?(filter_refs ++ sort_refs, &(&1.relationship_path == [])) do
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

  @doc "A relationship path as the load that reaches its end: `[:a, :b]` is `{:a, :b}`."
  @spec nested_load([atom]) :: atom | {atom, term}
  def nested_load(path) do
    [last | rest] = Enum.reverse(path)
    Enum.reduce(rest, last, fn name, acc -> {name, acc} end)
  end

  # The relationship paths of the sort that reach a changed resource, which the sort loads before it evaluates.
  defp sort_paths(resource, sort_refs, changed) do
    for ref <- sort_refs,
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

  defp sort_refs(_resource, _other), do: []

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
    |> Enum.flat_map(&reached(resource, &1.relationship_path))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn reached, {:ok, changed} ->
      case Server.overlay?(id, reached) do
        {:ok, true} -> {:cont, {:ok, MapSet.put(changed, reached)}}
        {:ok, false} -> {:cont, {:ok, changed}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp affected_ref?(%{relationship_path: path}, resource, changed),
    do: Enum.any?(reached(resource, path), &MapSet.member?(changed, &1))

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
  defp selects(resource, refs) do
    refs
    |> Enum.flat_map(fn
      %{relationship_path: [], attribute: %{name: name}} when is_atom(name) ->
        [name]

      %{relationship_path: [first | _]} ->
        case Info.relationship(resource, first) do
          %{source_attribute: attribute} -> [attribute]
          _other -> []
        end

      _other ->
        []
    end)
    |> Enum.filter(&Info.attribute(resource, &1))
    |> Enum.uniq()
  end
end
