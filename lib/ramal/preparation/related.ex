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
  # in-memory check of the removed conjuncts for each base row the branch did not change; ADR 0047 narrows it below.
  #
  # An aggregate in a filter or sort (`herd_count >= 2`) is one more way to reach a relationship: the data layer counts
  # the base's herds, so its ref counts as reaching every resource on the aggregate's path, and a conjunct that
  # references an aggregate over a changed resource is removed like any other. `aggregates/1` hands the aggregates of
  # the removed conjuncts to the preparation, which computes them over the branch before it evaluates the conjunct.
  #
  # What the refs of a filter hold (`Ramal.Ash.filter_refs/2`): a ref under an `exists(...)` carries that path as a
  # prefix, and a sort on an aggregate holds an `Ash.Query.Aggregate` in place of the field name
  # (`{%Ash.Query.Aggregate{}, :desc}`).
  #
  # Narrowing (ADR 0047). Taking a conjunct out of the data-layer query makes the database return every row the other
  # conjuncts allow. For a leaf that reaches one changed `belongs_to` or `has_one` of one hop the query can keep a
  # rewritten form of it, which judges the rows whose related row the branch did not change by the base as before and
  # the others by the branch's version of the related row:
  #
  #     (paddock.name == "L07" and (is_nil(paddock_id) or paddock_id not in ^changed)) or paddock_id in ^matching
  #
  # `changed` are the keys of the related rows the branch has entries for (created, updated and destroyed), `matching`
  # those whose branch version satisfies the leaf (`Ash.Filter.Runtime.filter_matches/3` on the overlay's record, and a
  # blank record for a destroyed one, which is what the LEFT JOIN gives a missing row: `is_nil(paddock.name)` holds).
  # The `is_nil(paddock_id)` keeps a row without a related row on the database's judgement, where `not in` would make
  # it unknown. A `has_one` keeps its leaf as it is and adds `source_attribute in ^values`, the destination attribute
  # values of the branch's versions of the related rows, because the overlay does not hold the version a changed row
  # had in the base and so cannot name the sources it moved away from; those are only extra candidates, which the
  # check in Elixir drops. For the same reason a `has_one` leaf that a missing related row satisfies
  # (`is_nil(first_herd.name)`) is not narrowed: a source that lost its row starts to match, and the overlay cannot say
  # which.
  #
  # The rewrite only narrows. The conjunct stays among `removed`, so every row the database returns is checked in
  # Elixir as before; what the rewrite has to guarantee is that it never excludes a row the conjunct accepts. That
  # holds for a tree of `and` and `or` over such leaves (Kleene logic is monotone in them, so a leaf that is wrong only
  # where the true answer is unknown cannot change whether the tree is true). A `not` over a leaf that reaches the
  # changed relationship is not: the rewrite is exact about "true" and says "false" where the runtime says "unknown",
  # which `not` would turn into a match or a miss, so such a conjunct is left to Elixir whole. So is a leaf with an
  # `exists`, a calculation, an aggregate, a path of more than one hop, a root attribute next to the related one, a
  # `many_to_many`/`has_many` path, or a relationship with its own filter, read action, manual definition or `through`
  # path (ADR 0046).
  # The leaf is rebuilt with its path taken off by `Ramal.Ash.map_filter/2`, which stops on `{:halt, expression}`. The
  # keyword form (`[paddock_id: [in: ids], or: [...], not: [...]]`) is parsed by `Ash.Filter.parse/2` into expressions
  # that sit next to the ones of the query, and an unknown counts as no match in `Ramal.Ash.filter_matches/3`.

  alias Ash.Query.{BooleanExpression, Not, Ref}
  alias Ash.Resource.Info
  alias Ramal.Branch.Server

  @typedoc "What `plan/2` returns when a read cannot trust the data layer's judgement."
  @type plan :: %{
          required(:full) => Ash.Filter.t() | nil,
          required(:kept) => Ash.Filter.t() | nil,
          required(:data_layer) => Ash.Filter.t() | nil,
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
    with {:ok, plan} <- plan(query, id, narrow?: false), do: {:ok, plan != :safe}
  end

  @doc """
  `:safe` when the data layer's filter and sort can be trusted, or the `t:plan/0`: `removed` is the filter to evaluate
  in Elixir on the base rows, `kept` the conjuncts that reach no changed resource, `data_layer` the filter the database
  gets (`kept`, plus the narrowed form of each conjunct that has one, ADR 0047), `full` the whole filter for the
  overlay's records, and `select` the attributes the Elixir check needs on a base row that selects only some.

  ## Options

    * `:narrow?` - whether to build the narrowed conjuncts, which read the branch's entries of the related resource.
      Defaults to `true`; the check of `affected?/2` does not need them.
  """
  @spec plan(Ash.Query.t(), String.t(), keyword) ::
          {:ok, :safe | plan} | {:error, Ramal.Error.t()}
  def plan(query, id, opts \\ []) do
    filter_refs = refs(query.filter)
    sort_refs = Enum.flat_map(List.wrap(query.sort), &sort_refs(query.resource, &1))

    if Enum.all?(filter_refs ++ sort_refs, &(path_of(&1) == [])) do
      {:ok, :safe}
    else
      with {:ok, changed} <- changed_resources(query.resource, filter_refs ++ sort_refs, id) do
        build(query, changed, sort_refs, id, Keyword.get(opts, :narrow?, true))
      end
    end
  end

  defp build(query, changed, sort_refs, id, narrow?) do
    {kept, removed} =
      query.filter
      |> conjuncts()
      |> Enum.split_with(fn expression ->
        not Enum.any?(refs(expression), &affected_ref?(&1, query.resource, changed))
      end)

    sort? = Enum.any?(sort_refs, &affected_ref?(&1, query.resource, changed))
    context = %{resource: query.resource, domain: query.domain, changed: changed, id: id}

    if removed == [] and not sort? do
      {:ok, :safe}
    else
      plan(
        query,
        %{kept: kept, removed: removed, sort?: sort?, sort_refs: sort_refs, changed: changed},
        context,
        narrow?
      )
    end
  end

  defp plan(query, parts, context, narrow?) do
    %{kept: kept, removed: removed, sort?: sort?, sort_refs: sort_refs, changed: changed} = parts

    with {:ok, narrowed} <- if(narrow?, do: narrow_all(removed, context), else: {:ok, []}) do
      {:ok,
       %{
         full: query.filter,
         kept: filter_of(query.filter, kept),
         data_layer: filter_of(query.filter, kept ++ narrowed),
         removed: filter_of(query.filter, removed),
         select: selects(query.resource, Enum.flat_map(removed, &refs/1) ++ sort_refs),
         sort?: sort?,
         paths: sort_paths(query.resource, sort_refs, changed)
       }}
    end
  end

  # The narrowed form of each removed conjunct that has one (ADR 0047). A conjunct without stays out of the data-layer
  # query, as before.
  defp narrow_all(removed, context) do
    Enum.reduce_while(removed, {:ok, []}, fn conjunct, {:ok, narrowed} ->
      case narrow_expression(conjunct, context) do
        {:ok, expression} -> {:cont, {:ok, [expression | narrowed]}}
        :skip -> {:cont, {:ok, narrowed}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp narrow_expression(
         %BooleanExpression{op: op, left: left, right: right} = expression,
         context
       )
       when op in [:and, :or] do
    with {:ok, left} <- narrow_expression(left, context),
         {:ok, right} <- narrow_expression(right, context) do
      {:ok, %{expression | left: left, right: right}}
    end
  end

  # See the moduledoc note: under a `not` the rewrite could turn "unknown" into a match or a miss.
  defp narrow_expression(%Not{expression: inner} = expression, context) do
    if reaches_changed?(inner, context), do: :skip, else: {:ok, expression}
  end

  defp narrow_expression(leaf, context) do
    if reaches_changed?(leaf, context), do: narrow_leaf(leaf, context), else: {:ok, leaf}
  end

  defp reaches_changed?(expression, %{resource: resource, changed: changed}),
    do: Enum.any?(refs(expression), &affected_ref?(&1, resource, changed))

  defp narrow_leaf(leaf, context) do
    case single_hop(leaf, context.resource) do
      {:ok, %{type: :belongs_to} = relationship} -> narrow_belongs_to(leaf, relationship, context)
      {:ok, %{type: :has_one} = relationship} -> narrow_has_one(leaf, relationship, context)
      :error -> :skip
    end
  end

  # The relationship a leaf reaches when it is the one the rewrite can handle: every ref is a plain attribute of the
  # same one-hop path, and nothing else that Ash evaluates in a way the rewrite cannot reproduce on the related row
  # alone.
  defp single_hop(leaf, resource) do
    with [%{relationship_path: [name]} | _] <- Ramal.Ash.filter_refs(leaf, false),
         true <- pure_leaf?(leaf, name),
         %{type: type} = relationship when type in [:belongs_to, :has_one] <-
           Info.relationship(resource, name),
         true <- plain_relationship?(relationship) do
      {:ok, relationship}
    else
      _other -> :error
    end
  end

  defp plain_relationship?(relationship) do
    is_nil(Map.get(relationship, :filter)) and is_nil(Map.get(relationship, :read_action)) and
      is_nil(Map.get(relationship, :manual)) and Map.get(relationship, :no_attributes?) != true and
      is_nil(Map.get(relationship, :through)) and
      (relationship.type != :belongs_to or
         Info.primary_key(relationship.destination) == [relationship.destination_attribute])
  end

  defp pure_leaf?(%Ref{relationship_path: [name], attribute: %Ash.Resource.Attribute{}}, name),
    do: true

  defp pure_leaf?(%Ref{}, _name), do: false

  defp pure_leaf?(%{__operator__?: true, left: left, right: right}, name),
    do: pure_leaf?(left, name) and pure_leaf?(right, name)

  defp pure_leaf?(%{__function__?: true, arguments: arguments}, name),
    do: Enum.all?(arguments, &pure_leaf?(&1, name))

  defp pure_leaf?(%MapSet{} = set, name), do: Enum.all?(set, &pure_leaf?(&1, name))
  defp pure_leaf?(list, name) when is_list(list), do: Enum.all?(list, &pure_leaf?(&1, name))
  defp pure_leaf?({key, value}, name) when is_atom(key), do: pure_leaf?(value, name)

  defp pure_leaf?(%module{}, _name),
    do:
      module not in [
        Ash.Query.Exists,
        Ash.Query.Call,
        Ash.Query.Parent,
        Ash.Query.Not,
        Ash.Query.BooleanExpression,
        Ash.Query.Calculation,
        Ash.Query.Aggregate,
        Ash.CustomExpression
      ]

  defp pure_leaf?(_literal, _name), do: true

  # A belongs_to whose destination attribute is the primary key: one related row per source row, so the branch's version
  # of that row decides the leaf for the source rows that point at it.
  defp narrow_belongs_to(leaf, relationship, context) do
    destination = relationship.destination
    attribute = relationship.destination_attribute

    with {:ok, keys} <- Server.keys(context.id, destination),
         {:ok, slice, _count} <- Server.select(context.id, destination, [], nil),
         {:ok, matching} <- matching_values(leaf, destination, slice, attribute, context),
         {:ok, blank?} <- matches_blank?(leaf, destination, context) do
      present = MapSet.new(Map.keys(slice))
      deleted = Enum.reject(keys, &MapSet.member?(present, &1))
      matching = if blank?, do: matching ++ deleted, else: matching
      rewrite_belongs_to(leaf, relationship.source_attribute, keys, matching, context)
    end
  end

  defp matching_values(leaf, destination, slice, attribute, context) do
    records = for {_key, {_kind, record}} <- slice, do: record

    with {:ok, matches} <-
           Ramal.Ash.filter_matches(
             context.domain,
             records,
             on_destination(leaf, destination)
           ) do
      {:ok, Enum.map(matches, &Map.fetch!(&1, attribute))}
    end
  end

  # A destroyed related row is what a LEFT JOIN finds when there is none: every attribute is `nil`.
  defp matches_blank?(leaf, destination, context) do
    with {:ok, matches} <-
           Ramal.Ash.filter_matches(
             context.domain,
             [struct(destination)],
             on_destination(leaf, destination)
           ) do
      {:ok, matches != []}
    end
  end

  defp on_destination(leaf, destination) do
    expression =
      Ramal.Ash.map_filter(leaf, fn
        %Ref{} = ref -> {:halt, %{ref | relationship_path: []}}
        other -> other
      end)

    %Ash.Filter{resource: destination, expression: expression}
  end

  defp rewrite_belongs_to(leaf, source_attribute, changed, matching, context) do
    guard = [
      or: [
        [{source_attribute, [is_nil: true]}],
        [not: [{source_attribute, [in: changed]}]]
      ]
    ]

    with {:ok, guard} <- parse(context.resource, guard) do
      add_sources(
        BooleanExpression.optimized_new(:and, leaf, guard),
        source_attribute,
        matching,
        context
      )
    end
  end

  # The leaf as it is, or one more candidate set: the sources whose related row is one the branch has.
  defp add_sources(expression, _attribute, [], _context), do: {:ok, expression}

  defp add_sources(expression, attribute, values, context) do
    case parse(context.resource, [{attribute, [in: values]}]) do
      {:ok, extra} -> {:ok, BooleanExpression.optimized_new(:or, expression, extra)}
      :skip -> :skip
    end
  end

  defp parse(resource, statement) do
    case Ash.Filter.parse(resource, statement) do
      {:ok, %Ash.Filter{expression: expression}} -> {:ok, expression}
      {:error, _error} -> :skip
    end
  end

  # A has_one: the leaf stays as the database judges it, and the sources the branch's versions of the related rows point
  # at are added as candidates (see the moduledoc note on why the old ones cannot be named).
  #
  # A leaf that a source without a related row satisfies (`is_nil(first_herd.name)`) is not narrowed: a source whose
  # related row the branch destroyed or moved to another source starts to satisfy it, the overlay does not hold which
  # sources those are (a `:deleted` entry has no record, an update has only the new one), and the database judges them
  # by the base, where they still have their row.
  defp narrow_has_one(leaf, relationship, context) do
    with {:ok, slice, _count} <- Server.select(context.id, relationship.destination, [], nil),
         {:ok, false} <- matches_blank?(leaf, relationship.destination, context) do
      values =
        for {_key, {_kind, record}} <- slice,
            value = Map.get(record, relationship.destination_attribute),
            value != nil,
            uniq: true,
            do: value

      add_sources(leaf, relationship.source_attribute, values, context)
    else
      {:ok, true} -> :skip
      {:error, _} = error -> error
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

  @doc false
  @spec conjuncts(term) :: [term]
  def conjuncts(nil), do: []
  def conjuncts(%Ash.Filter{expression: expression}), do: conjuncts(expression)
  def conjuncts(true), do: []

  def conjuncts(%BooleanExpression{op: :and, left: left, right: right}),
    do: conjuncts(left) ++ conjuncts(right)

  def conjuncts(expression), do: [expression]

  @doc false
  @spec filter_of(Ash.Filter.t() | nil, [term]) :: Ash.Filter.t() | nil
  def filter_of(_filter, []), do: nil

  def filter_of(filter, expressions) do
    %{
      filter
      | expression: Enum.reduce(expressions, &BooleanExpression.optimized_new(:and, &2, &1))
    }
  end

  defp refs(nil), do: []
  defp refs(expression), do: Ramal.Ash.filter_refs(expression, true)

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
    case Ramal.Ash.hydrate_refs(expression, resource) do
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
