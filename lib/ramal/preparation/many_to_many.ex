defmodule Ramal.Preparation.ManyToMany do
  @moduledoc false
  # PROTOTYPE for ADR 0017 (proposed). Makes a many_to_many load inside a branch see the links the branch created or
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
  # destination rows are patched and sorted.

  import Ash.Expr, only: [ref: 1]

  alias Ash.Resource.Info
  alias Ramal.Branch.Server
  alias Ramal.Current

  require Ash.Expr
  require Ash.Query

  @doc """
  Returns `{:ok, query, links}` when the query is the destination read of a many_to_many load whose join resource the
  branch has changed, with the lateral join replaced by a filter. `links` maps a destination key to the primary keys of
  the source records that link to it. Returns `:skip` for every other query.
  """
  @spec rewrite(Ash.Query.t(), String.t()) ::
          {:ok, Ash.Query.t(), map} | :skip | {:error, term}
  def rewrite(query, id) do
    with false <- paged?(query),
         {records, [source_hop, through_hop]} when is_list(records) <-
           query.context[:data_layer][:lateral_join_source],
         {_source_query, source_attribute, source_on_join, %{type: :many_to_many} = relationship} <-
           source_hop,
         {through_query, destination_on_join, destination_attribute, _join_relationship} <-
           through_hop,
         {:ok, slice} when map_size(slice) > 0 <- Server.slice(id, relationship.through) do
      links(query, id, records, through_query, %{
        source: relationship.source,
        source_attribute: source_attribute,
        source_on_join: source_on_join,
        destination_on_join: destination_on_join,
        destination_attribute: destination_attribute
      })
    else
      {:ok, _empty_slice} -> :skip
      {:error, error} -> {:error, error}
      _ -> :skip
    end
  end

  # A paged load goes through `Ash.Page` values that this rewrite does not rebuild (ADR 0017).
  defp paged?(query), do: query.page not in [nil, false]

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
        |> drop_lateral_join()
        |> Ash.Query.filter(^ref(dest_attr) in ^destination_values)

      {:ok, query, %{by_destination: links, attribute: dest_attr}}
    end
  end

  defp drop_lateral_join(query) do
    update_in(query.context[:data_layer], &Map.delete(&1, :lateral_join_source))
  end

  @doc """
  Tags the patched destination rows with their source records and applies the per-source `limit` and `offset`.
  """
  @spec expand([struct], map, non_neg_integer | nil, pos_integer | nil) :: [struct]
  def expand(rows, %{by_destination: links, attribute: attribute}, offset, limit) do
    rows
    |> Enum.flat_map(fn row ->
      for source <- Map.get(links, Map.get(row, attribute), []),
          do: %{row | __lateral_join_source__: source}
    end)
    |> Enum.group_by(& &1.__lateral_join_source__)
    |> Enum.flat_map(fn {_source, group} ->
      group |> Enum.drop(offset || 0) |> take(limit)
    end)
  end

  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Enum.take(rows, limit)
end
