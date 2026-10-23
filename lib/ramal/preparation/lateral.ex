defmodule Ramal.Preparation.Lateral do
  @moduledoc false
  # ADR 0046. Makes the load of a relationship with a `through` path of several hops (`has_many :herd_moves, Move,
  # through: [:herds, :moves]`) see the rows the branch created, changed and destroyed on the way.
  #
  # Confirmed against Ash 3.37 and AshPostgres 2.15.1 / AshSql 0.8.3:
  #
  #   * A `through` relationship is loaded with a lateral join whenever the data layer can lateral join its resources
  #     (`lateral_join?/4` in `deps/ash/lib/ash/actions/read/relationships.ex` answers true for
  #     `is_list(relationship.through)` after that check), and
  #     `with_lateral_join_query/4` of that file puts `context.data_layer.lateral_join_source = {records, path}` on the
  #     destination's read. `expand_through_path/2` flattens a `through` that names another `through`; a many_to_many is
  #     one hop of it, not two.
  #   * `path` has one entry per hop, `{entry_query, source_attribute, destination_attribute, relationship}`, where the
  #     attributes and the relationship are those of hop *i*, so `source_attribute` is a field of the hop's source
  #     resource and `destination_attribute` a field of its destination. `entry_query` of the first hop is the source
  #     read; of every later hop it is a read of the hop's *source* resource, which is the destination of the hop before
  #     it. Ash hydrates it with the actor, `authorize?`, the tenant and the shared context.
  #   * AshPostgres joins `destination.destination_attribute_n = through_n.source_attribute_n` back to
  #     `through_1.destination_attribute_1 = source.source_attribute_1` inside one lateral subquery
  #     (`lateral_join_query/3` and `build_through_queries/4` in `deps/ash_postgres/lib/data_layer.ex`), so the
  #     intermediate tables are the database's rows; the branch's are not in it.
  #   * A many_to_many as a hop is broken in Ash 3.37: the path holds the many_to_many relationship itself, whose
  #     `source_attribute` and `destination_attribute` are the primary keys, and AshPostgres joins
  #     `vets JOIN herds ON herds.id = vets.id`, ignoring the join resource. The load is empty for every record, with or
  #     without a branch, so a path with a many_to_many entry is left to the database. Ash after 3.37 (commit 3c4b41a,
  #     "read each step of a through relationship the way its relationship reads") expands the hop into the join
  #     resource and its destination, so every entry is a plain hop and the path is walked like any other
  #     (`test/ramal/through_test.exs` holds on both).
  #   * That Ash also reads each later hop with the arriving relationship's limit, and adds a step of its own when the
  #     last relationship has a limit, an offset or a `parent` filter. A walk reads a hop for all sources at once, so a
  #     limit there would cut the wrong rows: an entry query with a limit or an offset is left to the database too.
  #
  # The walk. Each source record reaches the values of `source_attribute_1`. For each later hop the entry query is read
  # (through Ramal's own preparation, so it is the patched read) with `destination_attribute_(i-1) in ^reached`, and
  # each row carries the sources of the value it matched over to its own `source_attribute_i`. On the last hop the
  # lateral join is dropped from the destination read, which is filtered by `destination_attribute_n in ^reached`; the
  # rows are tagged with every source that reaches them, once per source, by `Ramal.Preparation.ManyToMany.expand/4`,
  # which also applies the per-source limit and offset. The result is what the SQL gives: a destination row once for
  # each source record that reaches it.
  #
  # Left to the database (as a lateral load with no overlay entry on the path is): a path that has a hop with a
  # relationship filter (the SQL applies it in a place the walk does not reproduce), a hop read with a limit or an
  # offset, a `distinct`, and a `parent` expression in the relationship's filter or sort, which needs the join to be
  # evaluated. A row the branch created is not in such a load, since the database's join never reached it
  # (`drop_unplaced/2` in `Ramal.Preparation`).

  import Ash.Expr, only: [ref: 1]

  alias Ash.Resource.Info
  alias Ramal.Branch.Server
  alias Ramal.Current

  require Ash.Expr
  require Ash.Query

  @doc """
  Returns `{:ok, query, links}` when `query` is the destination read of a load with a `through` path of several hops
  that the branch changed (an intermediate resource or the destination has overlay entries), with the lateral join
  replaced by a filter. `links` has the shape `Ramal.Preparation.ManyToMany.expand/4` takes. Returns `:skip` for every
  other load, and `{:error, error}` when a hop cannot be read.
  """
  @spec rewrite(Ash.Query.t(), String.t(), {[struct], [tuple]}) ::
          {:ok, Ash.Query.t(), map} | :skip | {:error, term}
  def rewrite(query, id, {records, path} = source) do
    with true <- supported?(query, path),
         {:ok, true} <- touched?(query, id, path),
         {:ok, reach} <- walk(path, records, id) do
      {_query, _source_attribute, destination_attribute, _relationship} = List.last(path)
      keys = Map.keys(reach)

      query =
        query
        |> Ramal.Ash.drop_lateral_source()
        |> Ash.Query.filter(^ref(destination_attribute) in ^keys)

      {:ok, query,
       %{by_destination: reach, attribute: destination_attribute, lateral_source: source}}
    else
      {:error, error} -> {:error, error}
      _ -> :skip
    end
  end

  # The first entry query is the sources' own read, whose page is not a hop's.
  defp supported?(query, [_first | rest] = path) do
    Enum.all?(path, fn {_entry, _source, _destination, relationship} ->
      relationship.type != :many_to_many and relationship.filter in [nil, []]
    end) and Enum.all?(rest, &unlimited?/1) and query.distinct in [nil, []] and
      not parent_expr?(query)
  end

  defp unlimited?({entry, _source, _destination, _relationship}),
    do: entry.limit == nil and entry.offset in [nil, 0]

  # The relationship the query loads is not in the path (only its hops are); Ash tells the read which it is.
  defp parent_expr?(query) do
    with %{source: source, name: name} <- Ramal.Ash.accessing_from(query),
         %{} = relationship <- Info.relationship(source, name) do
      Ramal.Ash.has_parent_expr?(relationship)
    else
      _ -> false
    end
  end

  # The first hop reads the sources, which are already patched. The load changes when a resource after it does.
  defp touched?(query, id, [_first | rest]) do
    resources = [query.resource | Enum.map(rest, fn {entry, _, _, _} -> entry.resource end)]

    Enum.reduce_while(resources, {:ok, false}, fn resource, _ ->
      case Server.overlay?(id, resource) do
        {:ok, true} -> {:halt, {:ok, true}}
        {:ok, false} -> {:cont, {:ok, false}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # `reach` maps a value to the primary keys of the source records that reach it, without repeats.
  defp walk([{_q, source_attribute, _d, relationship} | rest] = path, records, id) do
    primary_key = Info.primary_key(relationship.source)

    start =
      records
      |> Enum.reject(&is_nil(Map.get(&1, source_attribute)))
      |> Enum.group_by(&Map.get(&1, source_attribute), &Map.take(&1, primary_key))
      |> Map.new(fn {value, sources} -> {value, Enum.uniq(sources)} end)

    walk_hops(Enum.zip(path, rest), start, id)
  end

  defp walk_hops([], reach, _id), do: {:ok, reach}

  defp walk_hops([{{_, _, destination_attribute, _}, next} | hops], reach, id) do
    {entry_query, next_source_attribute, _, _} = next
    values = Map.keys(reach)

    entry_query =
      entry_query
      |> Ash.Query.set_context(Current.shared_context(id))
      |> Ash.Query.filter(^ref(destination_attribute) in ^values)

    with {:ok, rows} <- Ash.read(entry_query, page: false) do
      walk_hops(hops, carry(rows, reach, destination_attribute, next_source_attribute), id)
    end
  end

  defp carry(rows, reach, from, to) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      sources = Map.get(reach, Map.get(row, from), [])

      case Map.get(row, to) do
        nil -> acc
        _value when sources == [] -> acc
        value -> Map.update(acc, value, sources, &(&1 ++ sources))
      end
    end)
    |> Map.new(fn {value, sources} -> {value, Enum.uniq(sources)} end)
  end
end
