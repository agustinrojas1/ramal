defmodule Ramal.Preparation do
  @moduledoc """
  The read preparation `Ramal.Resource` installs on every read action.

  Inside `Ramal.run/2` it makes a read see the base data patched with the branch's overlay. Outside a branch it
  returns the query untouched, so the action behaves as if the extension were absent.

  How it works, confirmed against Ash 3.37 (`lib/ash/actions/read/read.ex`):

    * `Ash.Query.before_action/2` hooks run after all preparations and before the data-layer query is built, so a hook
      there can still remove `limit` and `offset`. The base query keeps its filter, so Postgres still narrows the rows.
    * `Ash.Query.after_action/2` hooks receive the base rows after the data layer and before relationship loads,
      runtime calculations and the not-found check of `Ash.get/3`. Patching there means loads, calculations and
      `Ash.get/3` all see the patched rows.
    * A many_to_many load is one SQL query that joins the join table in the database. When the branch changed the join
      resource, a helper in lib/ramal/preparation/many_to_many.ex swaps that join for the patched join rows (ADR 0017).
    * A relationship load runs a read on the related resource through its own preparation, in a task that does not
      inherit the process dictionary. The branch id therefore also travels in the query's `shared` context, which
      Ash copies into related queries (`lib/ash/actions/read/relationships.ex`).
    * `distinct` is applied after the patch, not by the data layer: while the overlay touches the resource the base
      query is read without it and the patch keeps the first row of each group in the order of `distinct_sort` (or
      `sort`). Otherwise a group whose database pick was destroyed in the branch vanished and a group got a second row
      from the branch. A distinct on an attribute compares the attribute. A distinct on a calculation is evaluated in
      memory on the patched rows by `Ash.Query.apply_to/3` (documented in Ash 3.37; it loads the calculation with
      `reuse_values?: true`, so a row the branch changed is judged by its new values, and one the branch created has a
      value at all). That needs every attribute the calculation reads, so it is done only when the query selects all of
      them. A distinct on an aggregate, a calculation in a query that selects some attributes, or any distinct on a
      many_to_many read keeps the data layer's.
    * Filters are evaluated on overlay records with `Ash.Filter.Runtime.filter_matches/4` and sorting uses
      Ash.Actions.Sort.runtime_sort/3.

  Every base row the read returns is also fingerprinted (`Ramal.Resource.fingerprint/1`) for the staleness check at
  merge time, unless the query selected only some attributes.

  Known limits in 0.1, documented rather than hidden:

    * an expression calculation is evaluated in memory on the records the branch created or changed, and for a filter
      on one (`load_calculations/3`, `matching_keys/2`); a calculation with its own module, and aggregates, are not
      computed over the overlay, and reading an aggregate emits `[:ramal, :read, :unpatched_aggregate]`. `Ramal.aggregate/4` is the exact alternative for the common kinds;
    * overlay records are added without running the action's `authorize_results` checks, though the query's filter,
      including any policy filter, is applied to them;
    * `Ash.load/3` onto a record the branch changed reselects the relationship's source attribute (for example
      `paddock_id`) from the data layer, and that reselect runs none of the read hooks (`reselect_and_load/6` in
      `lib/ash/actions/read/read.ex`), so a foreign key the branch changed is not seen and the load follows the
      database's. Pass `reuse_values?: true`, which skips the reselect, or load through a read
      (`Ash.Query.load/2`), which goes through this preparation;
    * paginated reads (`page:`) are paged by the database and patched afterwards, so pages can be short or miss rows
      created in the branch, and `count` is the database's.

  ## Example

      # With a branch current, the same call returns rows created in the branch.
      Ramal.run!(branch, fn -> Ash.read!(MyApp.Farm.Herd) end)
  """
  use Ash.Resource.Preparation

  alias Ash.Actions.Sort
  alias Ash.Filter.Runtime
  alias Ash.Resource.Info
  alias Ramal.Branch.Server
  alias Ramal.{Current, Overlay, Prefilter, Resource, Telemetry}
  alias Ramal.Preparation.ManyToMany

  @impl true
  def prepare(query, _opts, _context) do
    case Current.resolve(query.context) do
      nil ->
        query

      id ->
        case Resource.ensure_untenanted(query.resource, query.tenant) do
          :ok ->
            query
            |> Ash.Query.set_context(Current.shared_context(id))
            |> Ash.Query.before_transaction(&record_calculations/1)
            |> Ash.Query.before_action(&before_data_layer(&1, id))
            |> Ash.Query.after_action(&after_data_layer(&1, &2, id))

          {:error, error} ->
            Ash.Query.add_error(query, error)
        end
    end
  end

  # The calculations are read in a `before_transaction` hook, not in `prepare/3` and not in the `before_action` hook:
  # this preparation runs before the action's own `prepare`, so a calculation the action loads is not in
  # `query.calculations` yet when `prepare/3` runs, and Ash unsets `query.calculations` just before the `before_action`
  # hooks (`do_read/5` in `lib/ash/actions/read/read.ex`, Ash 3.37). `before_transaction` hooks run after every
  # preparation and while the calculations are still there.
  defp record_calculations(query),
    do: Ash.Query.set_context(query, %{ramal: %{calculations: query.calculations}})

  # Without overlay entries for this resource nothing changes, so the query keeps its limit and offset and Postgres
  # does the paging. Stripping them is only needed when the overlay may add or remove rows.
  defp before_data_layer(query, id) do
    warn_unpatched_aggregates(query, id)

    case ManyToMany.rewrite(query, id) do
      {:ok, query, links} -> strip_paging(query, id, links)
      :skip -> strip_paging(query, id, nil)
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  defp strip_paging(query, id, links) do
    case Server.overlay?(id, query.resource) do
      {:ok, false} when links == nil ->
        Ash.Query.set_context(query, %{ramal: %{overlay?: false, limit: nil, offset: nil}})

      {:ok, overlay?} ->
        {query, distinct} = take_over_distinct(query, links)

        query
        |> Ash.Query.set_context(%{
          ramal: %{
            overlay?: overlay?,
            limit: query.limit,
            offset: query.offset,
            links: links,
            distinct: distinct
          }
        })
        |> Ash.Query.unset([:limit, :offset])

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  # `distinct` is applied by the data layer to the base rows, where a row the branch changed or destroyed still
  # stands for its group and a row the branch created is not in any group. When the overlay touches the resource the
  # preparation takes it over: the base query returns every row, and the patch keeps the first row of each group in
  # the order of `distinct_sort` (or `sort`), as DISTINCT ON does. Attributes and calculations are handled (a
  # calculation only in a query that selects every attribute, which evaluating it in memory needs); an
  # aggregate, or a many_to_many read, keeps the data layer's distinct.
  defp take_over_distinct(query, links) do
    pick = if query.distinct_sort in [nil, []], do: query.sort, else: query.distinct_sort

    cond do
      links != nil ->
        {query, nil}

      distinct_kind(query) == :attributes ->
        fields = for {field, _direction} <- query.distinct, do: field

        query =
          query
          |> Ash.Query.unset([:distinct, :distinct_sort])
          |> Ash.Query.ensure_selected(fields)

        {query, %{fields: fields, sort: pick}}

      distinct_kind(query) == :calculations ->
        distinct = Ash.Query.new(query.resource)
        distinct = %{distinct | distinct: query.distinct, distinct_sort: pick}
        {Ash.Query.unset(query, [:distinct, :distinct_sort]), %{query: distinct}}

      true ->
        {query, nil}
    end
  end

  # `:attributes` when every field is an attribute, `:calculations` when at least one is a calculation and the rest are
  # attributes and the query selects all of them, `nil` otherwise.
  defp distinct_kind(%{distinct: [_ | _] = distinct} = query) do
    kinds =
      Enum.map(distinct, fn
        {field, _direction} when is_atom(field) ->
          if Info.attribute(query.resource, field), do: :attribute, else: :other

        {%Ash.Query.Calculation{}, _direction} ->
          :calculation

        _other ->
          :other
      end)

    cond do
      :other in kinds -> nil
      :calculation in kinds and selects_all?(query) -> :calculations
      :calculation in kinds -> nil
      true -> :attributes
    end
  end

  defp distinct_kind(_query), do: nil

  # By the time the hook runs Ash has filled `select` with every attribute of a query that did not narrow it.
  defp selects_all?(%{select: nil}), do: true

  defp selects_all?(%{select: select, resource: resource}),
    do: Enum.all?(Info.attributes(resource), &(&1.name in select))

  defp after_data_layer(query, results, id) do
    %{overlay?: overlay?, limit: limit, offset: offset} = query.context.ramal
    links = query.context.ramal[:links]
    record_fingerprints(query.resource, results, id)

    # Rows are tagged with their source records after the patch, and paged per source, not as one list.
    {patch_limit, patch_offset} = if links, do: {nil, nil}, else: {limit, offset}

    with {:ok, patched} <- patch_rows(query, results, overlay?, patch_limit, patch_offset, id) do
      if links do
        {:ok, ManyToMany.expand(patched, links, offset, limit)}
      else
        {:ok, patched}
      end
    end
  end

  defp patch_rows(_query, results, false, _limit, _offset, _id), do: {:ok, results}

  defp patch_rows(query, results, true, limit, offset, id) do
    started = System.monotonic_time()

    with {:ok, patched, overlay_rows} <- patch(query, results, limit, offset, id) do
      Telemetry.read(
        :patch,
        %{
          base_rows: length(results),
          overlay_rows: overlay_rows,
          result_rows: length(patched),
          duration: System.monotonic_time() - started
        },
        %{branch_id: id, resource: query.resource}
      )

      {:ok, patched}
    end
  end

  # Staleness at merge time is measured from the first time the branch saw a row, so every base row a read returns is
  # fingerprinted before it is patched. Rows with an attribute that was not selected cannot be compared and are skipped.
  defp record_fingerprints(resource, results, id) do
    case Resource.fingerprints(resource, results) do
      [] -> :ok
      fingerprints -> Server.fingerprints(id, fingerprints)
    end

    :ok
  end

  # Only the overlay entries this read can use are fetched: those of the rows the base returned, and the records the
  # filter may accept. The branch process rules out the rest with `Ramal.Prefilter`, which never rejects a record the
  # filter accepts, and `matching_keys/2` runs the real filter on what is left.
  defp patch(query, results, limit, offset, id) do
    resource = query.resource
    base_keys = Enum.map(results, &Resource.key(resource, &1))

    with {:ok, slice, overlay_rows} <-
           Server.select(id, resource, base_keys, Prefilter.compile(query.filter)),
         {:ok, matching} <- matching_keys(query, slice),
         {:ok, patched} <-
           results
           |> Overlay.patch(slice, &MapSet.member?(matching, Resource.key(resource, &1)),
             key: &Resource.key(resource, &1),
             replace: &carry_lateral_source/2
           )
           |> load_calculations(slice, query),
         {:ok, distinct} <- distinct(patched, query) do
      patched =
        distinct
        |> sort(query)
        |> Enum.drop(offset || 0)
        |> take(limit)
        |> Enum.map(&apply_select(&1, query, slice))

      {:ok, patched, overlay_rows}
    end
  end

  # The data layer computes an expression calculation in SQL on the base row, so a record the branch created or changed
  # comes out of the overlay without it (`Ash.NotLoaded`) and a record the branch changed would carry the database's
  # value for the old attributes. Ash can evaluate the expression on a record in memory, which is what `Ash.load/3`
  # with `reuse_values?: true` does (the same call `Ash.Query.apply_to/3` makes), so the overlay's records get it here,
  # before they are filtered, sorted or trimmed by `select`, which need every attribute.
  defp load_calculations(rows, slice, query) do
    {from_overlay, from_base} =
      Enum.split_with(rows, &Map.has_key?(slice, Resource.key(query.resource, &1)))

    with [_ | _] <- from_overlay,
         {:ok, loaded} <- load_in_memory(from_overlay, query.context.ramal.calculations, query) do
      {:ok, reorder(rows, from_base ++ loaded, query.resource)}
    else
      [] -> {:ok, rows}
      {:error, _} = error -> error
    end
  end

  defp load_in_memory(records, calculations, query) do
    expressions =
      Map.filter(calculations, fn {_name, calculation} ->
        calculation.module == Ash.Resource.Calculation.Expression
      end)

    if expressions == %{} do
      {:ok, records}
    else
      load = %{Ash.Query.new(query.resource) | calculations: expressions}
      Ash.load(records, load, domain: query.domain, reuse_values?: true, authorize?: false)
    end
  end

  defp filter_calculations(query) do
    for %{relationship_path: [], attribute: %Ash.Query.Calculation{} = calculation} <-
          Ash.Filter.list_refs(query.filter, false, false, true),
        into: %{},
        do: {calculation.name, calculation}
  end

  # Keeps the order Overlay.patch produced, which the sort and offset after it start from.
  defp reorder(rows, loaded, resource) do
    by_key = Map.new(loaded, &{Resource.key(resource, &1), &1})
    Enum.map(rows, &Map.fetch!(by_key, Resource.key(resource, &1)))
  end

  # A many_to_many load (and a has_many load with a limit) is one SQL query whose rows each carry the source record they
  # belong to. Ash groups the rows by it (`lib/ash/actions/read/relationships.ex`) and drops a row without one, so an
  # overlay record that takes a base row's place has to keep that row's source.
  defp carry_lateral_source(
         %{__lateral_join_source__: source},
         %{__lateral_join_source__: nil} = record
       )
       when source != nil do
    %{record | __lateral_join_source__: source}
  end

  defp carry_lateral_source(_row, record), do: record

  # The keys of overlay records that satisfy the query's filter. Computed once for the whole slice, so a filter that
  # needs relationship data loads it in one batch.
  #
  # `Ash.Filter.Runtime` loads a calculation the filter references onto records that lack it through the data layer,
  # which computes it from the database row, so a record the branch changed would be judged by its old attributes
  # (`load_records_and_parent/5` in `lib/ash/filter/runtime.ex`). The expression calculations are evaluated in memory
  # first, which the runtime then finds already loaded.
  defp matching_keys(query, slice) do
    records = for {_key, {_kind, record}} <- slice, do: record

    with {:ok, records} <- load_in_memory(records, filter_calculations(query), query),
         {:ok, matches} <-
           Runtime.filter_matches(query.domain, records, query.filter) do
      {:ok, MapSet.new(matches, &Resource.key(query.resource, &1))}
    end
  end

  # Base rows come back from Postgres with only the selected attributes loaded. Overlay records are whole structs, so
  # they are trimmed the same way after filtering and sorting, which need every attribute.
  defp apply_select(record, %{select: select} = query, slice) when is_list(select) do
    if match?({_kind, _record}, Map.get(slice, Resource.key(query.resource, record))) do
      keep = select ++ Info.primary_key(query.resource)

      query.resource
      |> Info.attributes()
      |> Enum.reject(&(&1.name in keep))
      |> Enum.reduce(record, fn attribute, record ->
        Map.put(record, attribute.name, %Ash.NotLoaded{
          type: :attribute,
          field: attribute.name,
          resource: query.resource
        })
      end)
    else
      record
    end
  end

  defp apply_select(record, _query, _slice), do: record

  defp distinct(rows, %{context: %{ramal: %{distinct: %{fields: fields, sort: pick}}}} = query) do
    {:ok,
     rows
     |> sort_by(pick, query)
     |> Enum.uniq_by(fn row -> Enum.map(fields, &Map.get(row, &1)) end)}
  end

  # The query that `apply_to/3` runs has only the distinct fields and their pick order: the filter and the sort are
  # applied by this preparation, and `apply_to/3` would run the filter a second time on rows Postgres already filtered.
  defp distinct(rows, %{context: %{ramal: %{distinct: %{query: distinct}}}} = query) do
    Ash.Query.apply_to(distinct, rows, domain: query.domain)
  end

  defp distinct(rows, _query), do: {:ok, rows}

  defp sort_by(rows, pick, _query) when pick in [nil, []], do: rows

  defp sort_by(rows, pick, query),
    do: Sort.runtime_sort(rows, pick, resource: query.resource, domain: query.domain)

  defp sort(rows, %{sort: sort} = query) when sort not in [nil, []] do
    Sort.runtime_sort(rows, sort, resource: query.resource, domain: query.domain)
  end

  defp sort(rows, _query), do: rows

  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Enum.take(rows, limit)

  defp warn_unpatched_aggregates(query, id) do
    if selects_aggregate?(query) do
      Telemetry.read(:unpatched_aggregate, %{count: 1}, %{branch_id: id, resource: query.resource})
    end
  end

  defp selects_aggregate?(query) do
    map_size(query.aggregates) > 0 or
      Enum.any?(List.wrap(query.load), fn
        name when is_atom(name) -> Info.aggregate(query.resource, name) != nil
        {name, _} when is_atom(name) -> Info.aggregate(query.resource, name) != nil
        _ -> false
      end)
  end
end
