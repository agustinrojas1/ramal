defmodule Ramal.Preparation.ManyToMany do
  @moduledoc false
  # ADR 0017. Makes a many_to_many load inside a branch see the links the branch created or
  # destroyed.
  #
  # AshPostgres loads a many_to_many with one SQL query that joins the join table in the database. The destination's
  # read gets `context.data_layer.lateral_join_source = {source_records, path}`, where for a many_to_many the path is
  #
  #     [{source_query, source_attribute, source_attribute_on_join_resource, relationship},
  #      {through_query, destination_attribute_on_join_resource, destination_attribute, join_relationship}]
  #
  # (`with_lateral_join_query/4` and the many_to_many clause of it in deps/ash/lib/ash/actions/read/relationships.ex).
  # `through_query` is a read of the join resource that Ash already hydrated with the join relationship's filter, the
  # actor, `authorize?`, the tenant and the shared context, so reading it goes through Ramal's own preparation and sees
  # the branch's links.
  #
  # When the branch holds no entry for the join resource the SQL is right and nothing changes. Otherwise the lateral
  # join is dropped from the query and replaced by a filter on the destination keys the patched join rows name; the
  # rows come back once per source record that links to them, each tagged with `__lateral_join_source__` the way the
  # data layer would (the primary key of the source record, a shape `attach_lateral_join_related_records/4` accepts).
  # Ash itself does the same in `do_fetch_related_records/5` for a many_to_many that is not loaded laterally, with the
  # source attribute value as the tag.
  #
  # Per-source `limit` and `offset` are what the lateral subquery applied; they are applied here per source after the
  # destination rows are patched and sorted. The same is done for the lateral read of a has_many (one hop) that has a
  # limit, an offset or a page, when the branch changed its destination, and a page is cut per source by the last
  # `before_action` hook of `Ramal.Preparation` (ADR 0040). A `through` path of several hops is walked by
  # `Ramal.Preparation.Lateral` (ADR 0046) and hands back the same tags.

  import Ash.Expr, only: [ref: 1]

  alias Ash.Resource.Info
  alias Ramal.Branch.Server
  alias Ramal.Current
  alias Ramal.Preparation.Lateral

  require Ash.Expr
  require Ash.Query

  @doc """
  Returns `{:ok, query, links}` when the query is the destination read of a lateral load (a many_to_many, or a has_many
  read with a limit, an offset or a page) that the database cannot answer once the branch has changed what the load
  reads, with the lateral join replaced by a filter. `links` maps a destination key to the source records that reach
  it, and keeps the lateral join the query had in `:lateral_source`. Returns `:skip` for every other query.
  """
  @spec rewrite(Ash.Query.t(), String.t()) ::
          {:ok, Ash.Query.t(), map} | :skip | {:error, term}
  def rewrite(query, id) do
    case Ramal.Ash.lateral_source(query) do
      {records, [source_hop, through_hop]} = source when is_list(records) ->
        if join_pair?(source_hop, through_hop),
          do: many_to_many(query, id, source, source_hop, through_hop),
          else: Lateral.rewrite(query, id, source)

      {records, [hop]} = source when is_list(records) ->
        direct(query, id, source, hop)

      {records, [_, _, _ | _]} = source when is_list(records) ->
        Lateral.rewrite(query, id, source)

      _ ->
        :skip
    end
  end

  # A many_to_many load is the pair of the relationship and its join relationship; a `through` path of two hops has
  # two relationships of its own (ADR 0046).
  defp join_pair?(
         {_, _, _, %{type: :many_to_many, join_relationship: join_name, source: source}},
         {_, _, _, %{name: join_name, source: source}}
       ),
       do: true

  defp join_pair?(_source_hop, _through_hop), do: false

  defp many_to_many(query, id, {records, _path} = source, source_hop, through_hop) do
    with {_source_query, source_attribute, source_on_join, %{type: :many_to_many} = relationship} <-
           source_hop,
         {through_query, destination_on_join, destination_attribute, _join_relationship} <-
           through_hop,
         {:ok, true} <- touched?(query, id, relationship.through, true) do
      links(query, id, records, through_query, %{
        source: relationship.source,
        source_attribute: source_attribute,
        source_on_join: source_on_join,
        destination_on_join: destination_on_join,
        destination_attribute: destination_attribute,
        lateral_source: source
      })
    else
      {:ok, false} -> :skip
      {:error, error} -> {:error, error}
      _ -> :skip
    end
  end

  # A has_many (or any relationship of one hop) read with a limit, an offset or a page is one lateral join that limits
  # per source record. When the branch changed the destination the database's rows are not the ones to limit, so the
  # destination is read whole for every source and limited per source here. A relationship with a `parent` expression
  # in its filter or sort needs the join to evaluate it, and a `distinct` is applied by the join per source: those keep
  # the database's.
  defp direct(query, id, {records, _path} = source, hop) do
    {_source_query, source_attribute, destination_attribute, relationship} = hop

    with :many <- relationship.cardinality,
         false <- query.distinct not in [nil, []],
         false <- parent_expr?(relationship),
         true <- paging?(query),
         {:ok, true} <- touched?(query, id, nil, false) do
      primary_key = Info.primary_key(relationship.source)

      by_source =
        Enum.group_by(records, &Map.get(&1, source_attribute), &Map.take(&1, primary_key))

      values = Map.keys(by_source)

      query =
        query
        |> Ramal.Ash.drop_lateral_source()
        |> Ash.Query.filter(^ref(destination_attribute) in ^values)

      {:ok, query,
       %{by_destination: by_source, attribute: destination_attribute, lateral_source: source}}
    else
      {:error, error} -> {:error, error}
      _ -> :skip
    end
  end

  defp parent_expr?(relationship),
    do: Ramal.Ash.has_parent_expr?(relationship)

  defp paging?(query),
    do: query.page not in [nil, false] or query.limit != nil or query.offset != nil

  # Whether the branch changed a resource the load reads: the join resource, or the destination of a load that is
  # limited per source (the database's join is right for an unlimited one, which Ramal patches like any read).
  defp touched?(query, id, join_resource, join?) do
    with {:ok, join_touched?} <- join_touched?(id, join_resource, join?),
         {:ok, destination_touched?} <- Server.overlay?(id, query.resource) do
      {:ok, join_touched? or (destination_touched? and paging?(query))}
    end
  end

  defp join_touched?(id, resource, true) do
    with {:ok, slice} <- Server.slice(id, resource), do: {:ok, map_size(slice) > 0}
  end

  defp join_touched?(_id, _resource, false), do: {:ok, false}

  defp links(query, id, records, through_query, keys) do
    %{source_attribute: source_attr, source_on_join: source_on_join} = keys
    %{destination_on_join: dest_on_join, destination_attribute: dest_attr} = keys
    source_values = Enum.map(records, &Map.get(&1, source_attr))
    primary_key = Info.primary_key(keys.source)

    join_query =
      through_query
      |> Ash.Query.set_context(Current.shared_context(id))
      |> Ash.Query.filter(^ref(source_on_join) in ^source_values)

    with {:ok, join_rows} <- Ash.read(join_query, page: false) do
      by_source = Map.new(records, &{Map.get(&1, source_attr), Map.take(&1, primary_key)})

      links =
        Enum.reduce(join_rows, %{}, fn row, acc ->
          source = Map.fetch!(by_source, Map.get(row, source_on_join))
          Map.update(acc, Map.get(row, dest_on_join), [source], &[source | &1])
        end)

      destination_values = Map.keys(links)

      query =
        query
        |> Ramal.Ash.drop_lateral_source()
        |> Ash.Query.filter(^ref(dest_attr) in ^destination_values)

      {:ok, query,
       %{by_destination: links, attribute: dest_attr, lateral_source: keys.lateral_source}}
    end
  end

  @doc """
  Tags the patched destination rows with their source records and applies the per-source `limit` and `offset`.
  """
  @spec expand([struct], map, non_neg_integer | nil, pos_integer | nil) :: [struct]
  def expand(rows, %{by_destination: links, attribute: attribute}, offset, limit) do
    rows
    |> Enum.flat_map(fn row ->
      for source <- Map.get(links, Map.get(row, attribute), []),
          do: Ramal.Ash.tag_lateral(row, source)
    end)
    |> Enum.group_by(&Ramal.Ash.lateral_tag/1)
    |> Enum.flat_map(fn {_source, group} ->
      group |> Enum.drop(offset || 0) |> take(limit)
    end)
  end

  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Enum.take(rows, limit)
end
