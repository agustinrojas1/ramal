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
      value at all). That needs every attribute the calculation reads, so a query that selects some attributes is widened to
      all of them. A distinct on an aggregate, or any distinct on a many_to_many read, keeps the data layer's.
    * A filter or sort that reaches a relationship whose resource the branch changed (`paddock.name == "L07"` after the
      branch renamed the paddock) cannot be left to the data layer, which joins the base's rows. a helper in lib/ramal/preparation/related.ex
      takes the conjuncts that reach it out of the data-layer query, and `check_base_rows/3` evaluates them in Elixir on
      the base rows the branch did not change; a sort loads the relationship and evaluates the calculation in memory
      (ADR 0025). Relationships are loaded first with `reuse_values?: true` so the branch's foreign keys are used.
    * Filters are evaluated on overlay records with `Ash.Filter.Runtime.filter_matches/4` and sorting uses
      Ash.Actions.Sort.runtime_sort/3.
    * A query prepared outside a branch and read inside one is bound when it runs (ADR 0028): it carries a
      `before_transaction` hook, which Ash's atomic bulk update check ignores, and that hook installs the read hooks.

  Every base row the read returns is also fingerprinted (`Ramal.Resource.fingerprint/1`) for the staleness check at
  merge time, unless the query selected only some attributes.

  Known limits in 0.1, documented rather than hidden:

    * an expression calculation is evaluated in memory on the records the branch created or changed, and for a filter
      on one (`load_calculations/3`, `matching_keys/2`), and so is a calculation with its own module that has an
      expression (the data layer computes those too); a calculation with only `calculate/3` runs in Elixir on the
      patched rows already;
    * an aggregate the read loads is recomputed from the branch's rows after the patch (lib/ramal/preparation/aggregates.ex,
      ADR 0029). The kinds and shapes it cannot do keep the database's value and emit `[:ramal, :read, :unpatched_aggregate]`.
      A filter or sort on an aggregate is judged on the base rows;
    * overlay records are added without running the action's `authorize_results` checks, though the query's filter,
      including any policy filter, is applied to them;
    * `Ash.load/3` onto a record the branch changed reselects the relationship's source attribute (for example
      `paddock_id`) from the data layer, and that reselect runs none of the read hooks (`reselect_and_load/6` in
      `lib/ash/actions/read/read.ex`), so a foreign key the branch changed is not seen and the load follows the
      database's. Use `Ramal.load/3` (ADR 0030), pass `reuse_values?: true`, which skips the reselect, or load through a
      read (`Ash.Query.load/2`), which goes through this preparation;
    * a sort on text uses byte order once the overlay touches the resource, where Postgres uses its collation, so mixed-case
      text can come out in another order than outside the branch (ADR 0024);
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
  alias Ramal.Preparation.{Aggregates, ManyToMany, Related}

  @impl true
  def prepare(query, _opts, _context) do
    case Current.bind(query.context) do
      # A query prepared outside a branch may still be read inside one. `before_action` and `after_action` hooks
      # cannot be installed here: Ash refuses an atomic bulk update or destroy of a query that has one
      # (`lib/ash/actions/update/bulk.ex`, 3.37). A `before_transaction` hook is not on that list, and it runs before the
      # query's `before_action` hooks are read, so it installs them when it finds a branch current (ADR 0026).
      :none ->
        Ash.Query.before_transaction(query, &bind_late/1)

      {:ok, id, origin} ->
        install(query, id, origin)

      {:conflict, process, carried} ->
        Ash.Query.add_error(query, Current.conflict(what(query), process, carried))
    end
  end

  defp install(query, id, origin) do
    case Resource.ensure_untenanted(query.resource, query.tenant) do
      :ok ->
        query
        |> Ash.Query.set_context(Current.shared_context(id))
        |> Ash.Query.before_transaction(&record_calculations/1)
        |> Ash.Query.before_action(&before_data_layer(&1, id, origin))
        |> Ash.Query.after_action(&after_data_layer(&1, &2, id))

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  # Runs when a query prepared with no branch is executed. The hooks `install/3` adds are not in the list Ash is
  # walking, so `record_calculations/1` is called directly (the calculations are still on the query at this point).
  defp bind_late(query) do
    case Current.bind(query.context) do
      :none ->
        query

      {:ok, id, origin} ->
        query |> install(id, origin) |> record_calculations()

      {:conflict, process, carried} ->
        {:error, Current.conflict(what(query), process, carried)}
    end
  end

  # The calculations are read in a `before_transaction` hook, not in `prepare/3` and not in the `before_action` hook:
  # this preparation runs before the action's own `prepare`, so a calculation the action loads is not in
  # `query.calculations` yet when `prepare/3` runs, and Ash unsets `query.calculations` just before the `before_action`
  # hooks (`do_read/5` in `lib/ash/actions/read/read.ex`, Ash 3.37). `before_transaction` hooks run after every
  # preparation and while the calculations are still there.
  defp record_calculations(query),
    do: Ash.Query.set_context(query, %{ramal: %{calculations: query.calculations}})

  defp what(query), do: "the #{query.action.name} query of #{inspect(query.resource)}"

  # Without overlay entries for this resource nothing changes, so the query keeps its limit and offset and Postgres
  # does the paging. Stripping them is only needed when the overlay may add or remove rows.
  defp before_data_layer(query, id, origin) do
    case Current.verify(id, origin, what(query)) do
      :ok -> rewrite(query, id)
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  defp rewrite(query, id) do
    warn_unpatched_aggregates(query, id)

    case ManyToMany.rewrite(query, id) do
      {:ok, query, links} -> strip_paging(query, id, links, nil)
      :skip -> relate(query, id)
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  # A filter or sort through a relationship the branch changed cannot be left to the data layer (ADR 0025): the part of
  # the filter that reaches it comes out of the data-layer query and is checked in Elixir after the read.
  defp relate(query, id) do
    case Related.plan(query, id) do
      {:ok, :safe} ->
        strip_paging(query, id, nil, nil)

      {:ok, plan} ->
        query
        |> Ash.Query.ensure_selected(plan.select)
        |> relax(plan)
        |> strip_paging(id, nil, plan)

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  defp relax(query, %{kept: kept}), do: %{query | filter: kept}

  defp strip_paging(query, id, links, related) do
    case Server.overlay?(id, query.resource) do
      {:ok, false} when links == nil and related == nil ->
        Ash.Query.set_context(query, %{ramal: %{overlay?: false, limit: nil, offset: nil}})

      {:ok, overlay?} ->
        {query, distinct} = take_over_distinct(query, links)

        query
        |> Ash.Query.set_context(%{
          ramal: %{
            overlay?: overlay? or related != nil,
            limit: query.limit,
            offset: query.offset,
            links: links,
            distinct: distinct,
            related: related
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
  # the order of `distinct_sort` (or `sort`), as DISTINCT ON does. Attributes and calculations are handled; an
  # aggregate, or a many_to_many read, keeps the data layer's distinct. Evaluating a calculation in memory needs every
  # attribute it reads, so a query that selects some attributes is widened to all of them, as one that distinct on an
  # attribute is widened to that attribute.
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

        query =
          query
          |> Ash.Query.unset([:distinct, :distinct_sort])
          |> Ash.Query.ensure_selected(Enum.map(Info.attributes(query.resource), & &1.name))

        {query, %{query: distinct}}

      true ->
        {query, nil}
    end
  end

  # `:attributes` when every field is an attribute, `:calculations` when at least one is a calculation and the rest are
  # attributes, `nil` otherwise.
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
      :calculation in kinds -> :calculations
      true -> :attributes
    end
  end

  defp distinct_kind(_query), do: nil

  defp after_data_layer(query, results, id) do
    %{overlay?: overlay?, limit: limit, offset: offset} = query.context.ramal
    links = query.context.ramal[:links]
    record_fingerprints(query.resource, results, id)

    # Rows are tagged with their source records after the patch, and paged per source, not as one list.
    {patch_limit, patch_offset} = if links, do: {nil, nil}, else: {limit, offset}

    with {:ok, patched} <- patch_rows(query, results, overlay?, patch_limit, patch_offset, id),
         {:ok, patched} <- Aggregates.apply(patched, query, id) do
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
         {:ok, results} <- check_base_rows(query, results, slice),
         {:ok, matching} <- matching_keys(query, slice),
         {:ok, patched} <-
           results
           |> Overlay.patch(slice, &MapSet.member?(matching, Resource.key(resource, &1)),
             key: &Resource.key(resource, &1),
             replace: &carry_lateral_source/2
           )
           |> load_calculations(slice, query),
         {:ok, distinct} <- distinct(patched, query),
         {:ok, sorted} <- sort(distinct, query) do
      patched =
        sorted
        |> Enum.drop(offset || 0)
        |> take(limit)
        |> Enum.map(&apply_select(&1, query, slice))

      {:ok, patched, overlay_rows}
    end
  end

  # The data layer did not apply the conjuncts of the filter that reach a resource the branch changed (`Related`), so a
  # base row the branch did not touch is checked against them here, with relationships loaded through the patched
  # reads. A base row the branch did change is replaced by its overlay record, which `matching_keys/2` judges by the
  # whole filter.
  defp check_base_rows(
         %{context: %{ramal: %{related: %{removed: removed}}}} = query,
         results,
         slice
       )
       when removed != nil do
    {changed, untouched} =
      Enum.split_with(results, &Map.has_key?(slice, Resource.key(query.resource, &1)))

    with {:ok, loaded} <- load_for_filter(untouched, removed, query),
         {:ok, matches} <- Runtime.filter_matches(query.domain, loaded, removed) do
      keys = MapSet.new(matches, &Resource.key(query.resource, &1))

      {:ok,
       Enum.filter(
         results,
         &(&1 in changed or MapSet.member?(keys, Resource.key(query.resource, &1)))
       )}
    end
  end

  defp check_base_rows(_query, results, _slice), do: {:ok, results}

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
      Map.filter(calculations, fn {_name, calculation} -> data_layer_calculation?(calculation) end)

    if expressions == %{} do
      {:ok, records}
    else
      load = %{Ash.Query.new(query.resource) | calculations: expressions}
      Ash.load(records, load, domain: query.domain, reuse_values?: true, authorize?: false)
    end
  end

  # A calculation with an expression is computed by the data layer, whether it is written inline or in its own module
  # (`has_expression?/0` is defined by `use Ash.Resource.Calculation`); one with only `calculate/3` runs in Elixir after
  # this preparation's after_action hook, on the patched rows, so it needs nothing here.
  defp data_layer_calculation?(%{module: module}) do
    Code.ensure_loaded?(module) and function_exported?(module, :has_expression?, 0) and
      module.has_expression?()
  end

  # The filter the overlay's records are judged by: the whole one, which a read with a relaxed data-layer filter keeps.
  defp full_filter(%{context: %{ramal: %{related: %{full: full}}}}), do: full
  defp full_filter(query), do: query.filter

  defp filter_calculations(query) do
    for %{relationship_path: [], attribute: %Ash.Query.Calculation{} = calculation} <-
          Ash.Filter.list_refs(full_filter(query), false, false, true),
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
         {:ok, records} <- load_for_filter(records, full_filter(query), query),
         {:ok, matches} <-
           Runtime.filter_matches(query.domain, records, full_filter(query)) do
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

  # A sort through a relationship the branch changed is evaluated in memory first, with the relationship loaded through
  # the patched reads, as for a filter calculation (`load_in_memory/3`); the runtime sort then reuses those values
  # instead of asking the data layer, which would read the base's rows.
  defp sort(rows, %{sort: sort, context: %{ramal: %{related: %{sort?: true}}}} = query) do
    calculations =
      for {%Ash.Query.Calculation{} = calculation, _} <- sort,
          into: %{},
          do: {calculation.name, calculation}

    with {:ok, loaded} <- load_related(rows, query),
         {:ok, loaded} <- load_in_memory(loaded, calculations, query) do
      sorted =
        Sort.runtime_sort(loaded, sort,
          resource: query.resource,
          domain: query.domain,
          lazy?: true,
          rename_calcs?: false
        )

      # The relationships and calculations loaded to sort are not part of what the caller asked for.
      by_key = Map.new(rows, &{Resource.key(query.resource, &1), &1})
      {:ok, Enum.map(sorted, &Map.fetch!(by_key, Resource.key(query.resource, &1)))}
    end
  end

  defp sort(rows, %{sort: sort} = query) when sort not in [nil, []] do
    {:ok, Sort.runtime_sort(rows, sort, resource: query.resource, domain: query.domain)}
  end

  defp sort(rows, _query), do: {:ok, rows}

  defp load_related(rows, %{context: %{ramal: %{related: %{paths: paths}}}} = query) do
    load = Enum.map(paths, &Related.nested_load/1)

    Ash.load(rows, load,
      domain: query.domain,
      authorize?: false,
      reuse_values?: true,
      context: Map.take(query.context, [:shared])
    )
  end

  # `Ash.Filter.Runtime` loads a relationship the filter reaches with `Ash.load/3`, which reselects the source attribute
  # (`paddock_id`) from the data layer without running the read hooks, so a record whose foreign key the branch changed
  # would be judged by the database's. Loading it first with `reuse_values?: true`, which skips the reselect, goes
  # through the patched reads and leaves the runtime a loaded relationship to use.
  defp load_for_filter(records, filter, query) do
    case Related.loads(filter) do
      [] ->
        {:ok, records}

      load ->
        Ash.load(records, load,
          domain: query.domain,
          authorize?: false,
          reuse_values?: true,
          context: Map.take(query.context, [:shared])
        )
    end
  end

  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Enum.take(rows, limit)

  defp warn_unpatched_aggregates(query, id) do
    if Aggregates.unsupported(query) != [] do
      Telemetry.read(:unpatched_aggregate, %{count: 1}, %{branch_id: id, resource: query.resource})
    end
  end
end
