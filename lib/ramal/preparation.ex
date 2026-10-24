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
    * A relationship with a `through` path of several hops is one lateral join over the intermediate tables. When the
      branch changed a resource after the first hop, or the destination, lib/ramal/preparation/lateral.ex walks the hops
      with the patched reads instead and tags the destination rows with the sources that reach them (ADR 0046). A path
      with a many_to_many hop stays with the database, which is wrong for it with or without a branch.
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
    * A conjunct of the filter with a `fragment(...)` cannot be evaluated by `Ash.Filter.Runtime`, which gives unknown for
      SQL text, so the overlay's records are judged by the database instead: lib/ramal/preparation/fragments.ex sends them
      as an inline `VALUES` table that shadows the resource's table in one read-only query (ADR 0054), and refuses the read
      where the database cannot judge it right.
    * Filters are evaluated on overlay records with `Ash.Filter.Runtime.filter_matches/4` and sorting uses
      Ash.Actions.Sort.runtime_sort/3.
    * A paginated read (`page:`, `Ash.page!/2`, `Ash.stream!/2`) of a resource the overlay touches is paged here, not by
      the database: Ash adds a page's limit and offset after the `before_action` hooks, counts in the database and
      decides `more?` from the database's rows, so the last `before_action` hook reads the whole patched list, cuts the
      page out of it (lib/ramal/preparation/paged.ex) and gives Ash the rows with `Ash.Query.set_result/2` and the count
      with the `full_count` context key, both honoured in `lib/ash/actions/read/read.ex` (Ash 3.37). Offset and keyset
      pages, `count`, `more?` and the cursors are those of the patched list (ADR 0030). A relationship loaded with a page,
      a limit or an offset is one lateral join that limits per source record: when the branch changed its destination or
      its join resource, the rows of all the sources are read whole, tagged with their source and cut per source, and the
      page is handed to Ash the same way (ADR 0040). Without overlay entries for the resource the database pages as
      before.
    * `authorize_results` checks (the runtime half of a policy, which `Ash.Can` adds when `strict_check` cannot decide)
      run in the read action of Ash on the data layer's rows, before any `after_action` hook, so they would never see a row
      the branch created and would judge a row the branch changed or destroyed by the database's values. While the
      overlay touches the resource the last `before_action` hook takes them off the query and the `after_action` hook
      runs them on the patched rows, in Ash's order (ADR 0037).
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
      ADR 0029). The kinds and shapes it cannot do (`custom`, a join filter, a custom read action) keep the database's value and emit
      `[:ramal, :read, :unpatched_aggregate]`.
      A filter or sort on an aggregate is judged on the branch's numbers too: when the branch changed a resource on the
      aggregate's path the conjunct is evaluated in Elixir like a filter through a changed relationship (ADR 0032), and
      the aggregate is computed for the overlay's records, and for the rows a sort orders, before it is used;
    * `Ash.load/3` onto a record the branch changed reselects the relationship's source attribute (for example
      `paddock_id`) from the data layer, and that reselect runs none of the read hooks (`reselect_and_load/6` in
      `lib/ash/actions/read/read.ex`), so a foreign key the branch changed is not seen and the load follows the
      database's. Use `Ramal.load/3` (ADR 0031), pass `reuse_values?: true`, which skips the reselect, or load through a
      read (`Ash.Query.load/2`), which goes through this preparation;
    * a sort on text, once the overlay touches the resource, orders by the rank Postgres gives each value under the
      column's collation, from one read-only query per sort key (lib/ramal/collation.ex, ADR 0045), so `apple` comes before
      `Banana` as it does in the database. A resource on another data layer keeps byte order. A keyset cursor on text, and a
      comparison filter (`name > "b"`) on it, still compare bytes;
    * a paged read of a resource the overlay touches reads every row the filter matches and pages the list in Elixir,
      so it costs what an unpaged read does, not one page (ADR 0030, and per source for a relationship load, ADR 0040).

  ## Example

      # With a branch current, the same call returns rows created in the branch.
      Ramal.run!(branch, fn -> Ash.read!(MyApp.Farm.Herd) end)
  """
  use Ash.Resource.Preparation

  alias Ash.Resource.Info
  alias Ramal.Ash.Contract
  alias Ramal.Branch.Server
  alias Ramal.{Collation, Current, Overlay, Prefilter, Resource, Telemetry}
  alias Ramal.Preparation.{Aggregates, Fragments, ManyToMany, Paged, Placeholders, Related}

  @impl true
  def prepare(query, _opts, _context) do
    case Current.bind(query.context) do
      # A query prepared outside a branch may still be read inside one. `before_action` and `after_action` hooks
      # cannot be installed here: Ash refuses an atomic bulk update or destroy of a query that has one
      # (`lib/ash/actions/update/bulk.ex`, 3.37). A `before_transaction` hook is not on that list. A read, or a bulk
      # action that streams the query, runs it before the query's `before_action` hooks are read, so it installs them
      # when it finds a branch current (ADR 0026). An atomic bulk update never runs it, which is safe because inside a
      # branch `Ramal.Capture.atomic/3` refuses the atomic strategy (tripwires in test/ramal/ash_contract_test.exs).
      :none ->
        Ash.Query.before_transaction(query, &bind_late/1)

      # The Ash assumptions a read in a branch relies on are checked here, where the branch reads (ADR 0049). The
      # relationship ones are checked in `rewrite/2`, where a lateral load is handled: Ash puts the source records of a
      # load on the query after the preparations have run.
      {:ok, id, origin} ->
        case Contract.ensure(:core) do
          :ok -> install(query, id, origin)
          {:error, error} -> Ash.Query.add_error(query, error)
        end

      {:conflict, process, carried} ->
        Ash.Query.add_error(query, Current.conflict(what(query), process, carried))
    end
  end

  defp install(query, id, origin) do
    case Resource.ensure_tenant(query.resource, query.tenant, id) do
      :ok ->
        query
        |> Ash.Query.set_context(Current.shared_context(id))
        |> Ash.Query.before_transaction(&before_transaction(&1, id))
        |> Ash.Query.before_action(&before_data_layer(&1, id, origin))
        |> Ash.Query.after_action(&after_data_layer(&1, &2, id))

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  # Runs when a query prepared with no branch is executed. The hooks `install/3` adds are not in the list Ash is
  # walking, so `before_transaction/2` is called directly (the calculations are still on the query at this point).
  defp bind_late(query) do
    case Current.bind(query.context) do
      :none ->
        query

      {:ok, id, origin} ->
        with :ok <- Contract.ensure(:core),
             do: query |> install(id, origin) |> before_transaction(id)

      {:conflict, process, carried} ->
        {:error, Current.conflict(what(query), process, carried)}
    end
  end

  # The calculations are read in a `before_transaction` hook, not in `prepare/3` and not in the `before_action` hook:
  # this preparation runs before the action's own `prepare`, so a calculation the action loads is not in
  # `query.calculations` yet when `prepare/3` runs, and Ash unsets `query.calculations` just before the `before_action`
  # hooks (`do_read/5` in `lib/ash/actions/read/read.ex`, Ash 3.37). `before_transaction` hooks run after every
  # preparation and while the calculations are still there.
  #
  # It is also where the paging hook is added: the hooks are appended in the order they are added, and this one runs
  # after the `before_action` hooks of every preparation and of the action, so it pages the query as they left it.
  defp before_transaction(query, id) do
    query
    |> Ash.Query.set_context(%{ramal: %{calculations: query.calculations}})
    |> Ash.Query.before_action(&last_hook(&1, id))
  end

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

    # A lateral load is one Ramal walks over the branch's rows (ADR 0046, 0047), so it needs the relationship-pages
    # assumptions; any other load is Ash's own and needs none.
    case relationship_contract(query) do
      :ok -> rewrite_patched(query, id)
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  defp rewrite_patched(query, id) do
    case ManyToMany.rewrite(query, id) do
      {:ok, rewritten, links} ->
        rewritten |> keep_lateral(query, links) |> strip_paging(id, links, nil)

      :skip ->
        relate(query, id)

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  defp relationship_contract(query) do
    if Ramal.Ash.lateral_load?(query), do: Contract.ensure(:relationship_pages), else: :ok
  end

  # A paged lateral load is paged per source record by `Ash.Actions.Read` after the hooks (`drop_pagination_extra/3`
  # looks for the lateral join in the context of the query the hooks return), and the rows it gets from `page/2` are
  # tagged with their source, so the query keeps the join. The data layer never runs it: the page is the result.
  defp keep_lateral(rewritten, original, %{lateral_source: source}) do
    if Paged.lateral_plan(original) do
      Ramal.Ash.put_lateral_source(rewritten, source)
    else
      rewritten
    end
  end

  # A filter or sort through a relationship the branch changed cannot be left to the data layer (ADR 0025): the part of
  # the filter that reaches it comes out of the data-layer query and is checked in Elixir after the read.
  defp relate(query, id) do
    case Related.plan(query, id) do
      {:ok, :safe} ->
        strip_paging(query, id, nil, nil)

      {:ok, plan} ->
        case Fragments.check_removed(query, plan.removed) do
          :ok ->
            query
            |> Ash.Query.ensure_selected(plan.select)
            |> relax(plan)
            |> strip_paging(id, nil, plan)

          {:error, error} ->
            Ash.Query.add_error(query, error)
        end

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  defp relax(query, %{data_layer: filter}), do: %{query | filter: filter}

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

  # A paged read was patched, sorted and cut by `page/3`; its rows are the ones to return. Unless Ash did not paginate
  # it (a query with no limit after the `paginate` step, which an unpaginated read that `Ramal.Preparation.Paged` could
  # not tell apart is): then the whole list is the result.
  defp after_data_layer(%{context: %{ramal: %{paged?: true} = ramal}} = query, results, _id) do
    authorize(query, if(query.limit == nil, do: ramal.whole, else: results))
  end

  defp after_data_layer(query, results, id) do
    %{overlay?: overlay?, limit: limit, offset: offset} = query.context.ramal
    links = query.context.ramal[:links]
    record_fingerprints(query.resource, results, id)

    # Rows are tagged with their source records after the patch, and paged per source, not as one list.
    {patch_limit, patch_offset} = if links, do: {nil, nil}, else: {limit, offset}

    with {:ok, patched} <- patch_rows(query, results, overlay?, patch_limit, patch_offset, id),
         {:ok, patched} <- Aggregates.apply(patched, query, id) do
      authorize(
        query,
        if(links, do: ManyToMany.expand(patched, links, offset, limit), else: patched)
      )
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

  defp last_hook(query, id) do
    query |> defer_authorize_results() |> page(id)
  end

  # `authorize_results` hooks run on the data layer's rows, before the `after_action` hooks (`do_read/5` in
  # `lib/ash/actions/read/read.ex`, Ash 3.37), so they would judge the base rows and never see a record the overlay
  # adds. They are taken off the query here, once every `before_action` hook has run, and `authorize/2` runs them on
  # the patched rows. Without overlay entries for the resource nothing moves and Ash runs them as usual.
  defp defer_authorize_results(
         %{authorize_results: [_ | _] = checks, context: %{ramal: %{overlay?: true}}} = query
       ) do
    query
    |> Ash.Query.set_context(%{ramal: %{authorize_results: checks}})
    |> Map.put(:authorize_results, [])
  end

  defp defer_authorize_results(query), do: query

  # The loop of `run_authorize_results/2` in `lib/ash/actions/read/read.ex` (Ash 3.37), over the patched rows: the
  # checks in list order, each given the rows the one before it returned.
  defp authorize(query, results) do
    case query.context.ramal[:authorize_results] do
      [_ | _] = checks -> Enum.reduce_while(checks, {:ok, results}, &run_check(&1, &2, query))
      _none -> {:ok, results}
    end
  end

  defp run_check(check, {:ok, results}, query) do
    case check.(query, results) do
      {:ok, results} -> {:cont, {:ok, results}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  # A paginated read of a resource the overlay touches (ADR 0030). Ash would page the base in the database and the
  # patch would add every overlay record to every page, so the page is cut here, from the whole patched list, and
  # handed to Ash as the result of the data layer. The list is read by the same action, as a read of its own that
  # keeps this preparation's `after_action` hook, the query as the hooks left it and none of their hooks; the loads
  # wait for the rows of the page, which Ash loads as for any result.
  defp page(%{context: %{ramal: %{overlay?: true, links: nil}}} = query, id) do
    case Paged.plan(query) do
      nil -> query
      plan -> page(query, plan, id)
    end
  end

  # A paged relationship load (ADR 0038): the rows of every source record are read whole and each source is paged on its
  # own, as the database's lateral join would. The count is the source record's own aggregate (`Aggregates`).
  defp page(%{context: %{ramal: %{links: %{lateral_source: _}}}} = query, id) do
    case Paged.lateral_plan(query) do
      nil -> query
      plan -> page_by_source(query, plan, id)
    end
  end

  defp page(query, _id), do: query

  defp page_by_source(query, plan, id) do
    sorted = Paged.stable_sort(query)

    with {:ok, rows} <- read_whole_list(sorted, id),
         {:ok, page} <- Paged.cut_by_source(sorted, plan, rows) do
      query
      |> Ramal.Ash.set_page(page)
      |> Ash.Query.set_context(%{ramal: %{paged?: true, whole: rows}})
      |> put_source_count(plan, rows)
    else
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  # The count of a page of several sources is each source's own aggregate. The page of one source that `Ash.page/2` asks
  # for next is read again, and Ash counts it with a query of its own, which AshPostgres cannot build for a lateral
  # join (it fails the same way outside a branch), so that count is given here.
  defp put_source_count(query, %{count?: true}, rows) do
    {sources, _path} = query.context.ramal.links.lateral_source

    case sources do
      [_one] -> Ramal.Ash.put_full_count(query, length(rows))
      _many -> query
    end
  end

  defp put_source_count(query, _plan, _rows), do: query

  defp page(query, plan, id) do
    sorted = Paged.stable_sort(query)

    with {:ok, rows} <- read_whole_list(sorted, id),
         {:ok, page, count} <- Paged.cut(sorted, plan, rows) do
      query
      |> Ramal.Ash.set_page(page)
      |> Ash.Query.set_context(%{ramal: %{paged?: true, whole: rows}})
      |> put_full_count(plan, count)
    else
      {:error, error} -> Ash.Query.add_error(query, error)
    end
  end

  # `fetch_count/5` takes a count set here before it queries the database.
  defp put_full_count(query, %{count?: true}, count),
    do: Ramal.Ash.put_full_count(query, count)

  defp put_full_count(query, _plan, _count), do: query

  defp read_whole_list(query, id) do
    ramal = query.context.ramal

    # The checks run on the page, once, when this hook's list is the result (`after_data_layer/3`). A paged load is read
    # without its lateral join: the rows of all its sources are read together and tagged by `after_data_layer/3`.
    whole =
      query
      |> Ash.Query.unset([:page, :limit, :offset])
      |> Ramal.Ash.without_hooks()
      |> Ramal.Ash.drop_lateral_source()

    whole = %{
      whole
      | context: update_in(whole.context, [:ramal], &Map.delete(&1, :authorize_results)),
        load: [],
        calculations: ramal.calculations,
        after_action: [&after_data_layer(&1, &2, id)]
    }

    # The query's filter already holds what the policies added, and the rows are authorized when Ash reads the page.
    Resource.read_all(whole,
      actor: Ramal.Ash.actor(query),
      tenant: query.tenant,
      authorize?: false,
      domain: query.domain
    )
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
    key = Resource.key_fun(resource)
    base_keys = Enum.map(results, key)

    with {:ok, slice, overlay_rows} <-
           Server.select(id, resource, base_keys, Prefilter.compile(prefilter_filter(query))),
         {:ok, results} <- check_base_rows(query, results, slice, id),
         {:ok, matching} <- matching_keys(query, slice, id),
         {:ok, patched} <-
           results
           |> Overlay.patch(slice, &MapSet.member?(matching, key.(&1)),
             key: key,
             replace: &carry_lateral_source/2
           )
           |> drop_unplaced(query)
           |> load_calculations(slice, query),
         {:ok, distinct} <- distinct(patched, query),
         {:ok, sorted} <- sort(distinct, query, id) do
      patched =
        sorted
        |> Enum.drop(offset || 0)
        |> take(limit)
        |> Enum.map(&apply_select(&1, query, slice, key))

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
         slice,
         id
       )
       when removed != nil do
    key = Resource.key_fun(query.resource)
    {changed, untouched} = Enum.split_with(results, &Map.has_key?(slice, key.(&1)))

    with {:ok, loaded} <- load_for_filter(untouched, removed, query),
         {:ok, loaded} <- load_aggregates(loaded, Related.aggregates(removed), query, id),
         {:ok, matches} <- Ramal.Ash.filter_matches(query.domain, loaded, removed) do
      keys = MapSet.new(matches, key)
      {:ok, Enum.filter(results, &(&1 in changed or MapSet.member?(keys, key.(&1))))}
    end
  end

  defp check_base_rows(_query, results, _slice, _id), do: {:ok, results}

  # The data layer computes an expression calculation in SQL on the base row, so a record the branch created or changed
  # comes out of the overlay without it (`Ash.NotLoaded`) and a record the branch changed would carry the database's
  # value for the old attributes. Ash can evaluate the expression on a record in memory, which is what `Ash.load/3`
  # with `reuse_values?: true` does (the same call `Ash.Query.apply_to/3` makes), so the overlay's records get it here,
  # before they are filtered, sorted or trimmed by `select`, which need every attribute.
  defp load_calculations(rows, _slice, %{context: %{ramal: %{calculations: calculations}}})
       when calculations == %{},
       do: {:ok, rows}

  defp load_calculations(rows, slice, query) do
    key = Resource.key_fun(query.resource)
    {from_overlay, from_base} = Enum.split_with(rows, &Map.has_key?(slice, key.(&1)))

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

      Ash.load(records, load,
        domain: query.domain,
        tenant: query.tenant,
        reuse_values?: true,
        authorize?: false
      )
    end
  end

  # A calculation with an expression is computed by the data layer, whether it is written inline or in its own module
  # (`has_expression?/0` is defined by `use Ash.Resource.Calculation`); one with only `calculate/3` runs in Elixir after
  # this preparation's after_action hook, on the patched rows, so it needs nothing here.
  defp data_layer_calculation?(%{module: module}) do
    Code.ensure_loaded?(module) and function_exported?(module, :has_expression?, 0) and
      module.has_expression?()
  end

  # The overlay records the prefilter keeps are those the conjuncts that reach no changed resource may accept. A
  # narrowed conjunct is left out on purpose: it judges a row by the base's foreign key, an overlay record has its own.
  defp prefilter_filter(%{context: %{ramal: %{related: %{kept: kept}}}}), do: kept
  defp prefilter_filter(query), do: query.filter

  # The filter the overlay's records are judged by: the whole one, which a read with a relaxed data-layer filter keeps.
  defp full_filter(%{context: %{ramal: %{related: %{full: full}}}}), do: full
  defp full_filter(query), do: query.filter

  defp filter_calculations(filter) do
    for %{relationship_path: [], attribute: %Ash.Query.Calculation{} = calculation} <-
          Ramal.Ash.filter_refs(filter, true),
        into: %{},
        do: {calculation.name, calculation}
  end

  # Keeps the order Overlay.patch produced, which the sort and offset after it start from.
  defp reorder(rows, loaded, resource) do
    key = Resource.key_fun(resource)
    by_key = Map.new(loaded, &{key.(&1), &1})
    Enum.map(rows, &Map.fetch!(by_key, key.(&1)))
  end

  # A many_to_many load (and a has_many load with a limit) is one SQL query whose rows each carry the source record they
  # belong to. Ash groups the rows by it (`lib/ash/actions/read/relationships.ex`) and drops a row without one, so an
  # overlay record that takes a base row's place has to keep that row's source.
  defp carry_lateral_source(row, record) do
    source = Ramal.Ash.lateral_tag(row)

    if source != nil and Ramal.Ash.lateral_tag(record) == nil,
      do: Ramal.Ash.tag_lateral(record, source),
      else: record
  end

  # A lateral load left to the database (ADR 0046: a `through` path the walk does not cover) keeps the database's join,
  # which places each row under the source records it reached. A record the branch created reached none in that join, so
  # it is not part of the load, and Ash cannot group it: with no source tag, `attach_lateral_join_related_records/4` in
  # deps/ash/lib/ash/actions/read/relationships.ex calls the key function of a `through` relationship's missing source
  # attribute and raises. A rewritten load (`links`) tags its rows itself after the patch.
  defp drop_unplaced(records, %{context: %{ramal: ramal}} = query) do
    if ramal[:links] == nil and Ramal.Ash.lateral_load?(query),
      do: Enum.reject(records, &(Ramal.Ash.lateral_tag(&1) == nil)),
      else: records
  end

  # The keys of overlay records that satisfy the query's filter. Computed once for the whole slice, so a filter that
  # needs relationship data loads it in one batch.
  #
  # `Ash.Filter.Runtime` loads a calculation the filter references onto records that lack it through the data layer,
  # which computes it from the database row, so a record the branch changed would be judged by its old attributes
  # (`load_records_and_parent/5` in `lib/ash/filter/runtime.ex`). The expression calculations are evaluated in memory
  # first, which the runtime then finds already loaded.
  defp matching_keys(query, slice, id) do
    records = for {_key, {_kind, record}} <- slice, do: record
    {fragments, filter} = Fragments.split(full_filter(query))

    with {:ok, judged} <- judge_fragments(query, records, fragments),
         {:ok, records} <- load_in_memory(judged, filter_calculations(filter), query),
         {:ok, records} <- load_aggregates(records, Related.aggregates(filter), query, id),
         {:ok, records} <- load_for_filter(records, filter, query),
         {:ok, matches} <- Ramal.Ash.filter_matches(query.domain, records, filter) do
      {:ok, MapSet.new(matches, Resource.key_fun(query.resource))}
    end
  end

  # The conjuncts that hold a fragment are judged by the database on the branch's rows (ADR 0054), and the rest in
  # Elixir; a record must pass both.
  defp judge_fragments(_query, records, nil), do: {:ok, records}

  defp judge_fragments(query, records, fragments) do
    with {:ok, keys} <- Fragments.matching(query, records, fragments) do
      key = Resource.key_fun(query.resource)
      {:ok, Enum.filter(records, &MapSet.member?(keys, key.(&1)))}
    end
  end

  # Base rows come back from Postgres with only the selected attributes loaded. Overlay records are whole structs, so
  # they are trimmed the same way after filtering and sorting, which need every attribute.
  defp apply_select(record, %{select: select} = query, slice, key) when is_list(select) do
    if match?({_kind, _record}, Map.get(slice, key.(record))) do
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

  defp apply_select(record, _query, _slice, _key), do: record

  defp distinct(rows, %{context: %{ramal: %{distinct: %{fields: fields, sort: pick}}}} = query) do
    with {:ok, sorted} <- sort_by(rows, pick, query) do
      {:ok, Enum.uniq_by(sorted, fn row -> Enum.map(fields, &Map.get(row, &1)) end)}
    end
  end

  # The query that `apply_to/3` runs has only the distinct fields and their pick order: the filter and the sort are
  # applied by this preparation, and `apply_to/3` would run the filter a second time on rows Postgres already filtered.
  defp distinct(rows, %{context: %{ramal: %{distinct: %{query: distinct}}}} = query) do
    Ash.Query.apply_to(distinct, rows, domain: query.domain)
  end

  defp distinct(rows, _query), do: {:ok, rows}

  defp sort_by(rows, pick, _query) when pick in [nil, []], do: {:ok, rows}

  # Text is ordered by the database's collation (`Ramal.Collation`, ADR 0045); everything else by Ash's runtime sort.
  defp sort_by(rows, pick, query) do
    Placeholders.sorted(rows, pick, query.resource, fn lifted ->
      Collation.sort(lifted, pick,
        resource: query.resource,
        domain: query.domain,
        tenant: query.tenant
      )
    end)
  end

  # A sort through a relationship the branch changed is evaluated in memory first, with the relationship loaded through
  # the patched reads, as for a filter calculation (`load_in_memory/3`); the runtime sort then reuses those values
  # instead of asking the data layer, which would read the base's rows.
  defp sort(rows, %{sort: sort} = query, id) when sort not in [nil, []] do
    if memory_sort?(query) do
      memory_sort(rows, query, id)
    else
      sort_by(rows, sort, query)
    end
  end

  defp sort(rows, _query, _id), do: {:ok, rows}

  # A sort on an aggregate is evaluated in memory too: the rows the overlay supplies have no value for it, and a row
  # whose related rows the branch changed has the database's.
  defp memory_sort?(%{sort: sort, context: %{ramal: ramal}}),
    do: match?(%{sort?: true}, ramal[:related]) or Related.aggregates(sort) != %{}

  defp memory_sort(rows, %{sort: sort} = query, id) do
    calculations =
      for {%Ash.Query.Calculation{} = calculation, _} <- sort,
          into: %{},
          do: {calculation.name, calculation}

    with {:ok, loaded} <- load_related(rows, query),
         {:ok, loaded} <- load_sort_calculations(loaded, calculations, query),
         {:ok, loaded} <- load_aggregates(loaded, Related.aggregates(sort), query, id),
         {:ok, sorted} <-
           Placeholders.sorted(loaded, sort, query.resource, fn lifted ->
             Collation.sort(lifted, sort,
               resource: query.resource,
               domain: query.domain,
               tenant: query.tenant,
               lazy?: true,
               rename_calcs?: false
             )
           end) do
      # The relationships and calculations loaded to sort are not part of what the caller asked for.
      key = Resource.key_fun(query.resource)
      by_key = Map.new(rows, &{key.(&1), &1})
      {:ok, Enum.map(sorted, &Map.fetch!(by_key, key.(&1)))}
    end
  end

  # A sort calculation that only reads attributes, along to-one relationships, is evaluated here from the relationships
  # loaded onto the rows, a nil relationship giving nil as in SQL. `Ash.load/3` cannot do it: it evaluates an
  # expression calculation in memory only when every record has each path loaded (`Ash.Resource.loaded?/3` with
  # `strict?: true`, deps/ash/lib/ash/actions/read/calculations.ex, `try_evaluate/5`), a record whose relationship is
  # nil fails that check, and Ash then asks the data layer for the whole batch, which keeps the base's value on every
  # row. Any other calculation (an aggregate or another calculation in it, a to-many path, an expression Ash.Expr
  # cannot evaluate) still goes through `Ash.load/3`.
  defp load_sort_calculations(records, calculations, query) do
    {records, rest} =
      calculations
      |> Map.filter(fn {_name, calculation} -> data_layer_calculation?(calculation) end)
      |> Enum.reduce({records, %{}}, fn {name, calculation}, {records, rest} ->
        case evaluate_calculation(records, calculation, query) do
          {:ok, records} -> {records, rest}
          :error -> {records, Map.put(rest, name, calculation)}
        end
      end)

    load_in_memory(records, rest, query)
  end

  defp evaluate_calculation(records, calculation, query) do
    with {:ok, paths} <- Related.plain_paths(query.resource, calculation),
         {:ok, records} <- load_paths(records, paths, query),
         {:ok, values} <- evaluate_all(records, calculation, query) do
      {:ok, attach_values(records, calculation, values)}
    else
      _error -> :error
    end
  end

  defp load_paths(records, [], _query), do: {:ok, records}

  defp load_paths(records, paths, query) do
    Ash.load(records, Enum.map(paths, &Related.nested_load/1),
      domain: query.domain,
      tenant: query.tenant,
      authorize?: false,
      reuse_values?: true,
      context: Map.take(query.context, [:shared])
    )
  end

  defp evaluate_all(records, calculation, query) do
    context = calculation.context

    expression =
      calculation.module
      |> Ash.Resource.Calculation.expression(calculation.opts, context)
      |> Ash.Expr.fill_template(
        actor: context.actor,
        tenant: context.tenant,
        args: context.arguments,
        context: context.source_context
      )

    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, values} ->
      case Ash.Expr.eval(expression, record: record, resource: query.resource) do
        {:ok, %Ash.NotLoaded{}} -> {:halt, :error}
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        _error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp attach_values(records, %{load: load}, values) when not is_nil(load),
    do: Enum.zip_with(records, values, &Map.put(&1, load, &2))

  defp attach_values(records, %{name: name}, values) do
    Enum.zip_with(records, values, fn record, value ->
      %{record | calculations: Map.put(record.calculations, name, value)}
    end)
  end

  defp load_related(rows, %{context: %{ramal: %{related: %{paths: [_ | _] = paths}}}} = query) do
    load = Enum.map(paths, &Related.nested_load/1)

    Ash.load(rows, load,
      domain: query.domain,
      tenant: query.tenant,
      authorize?: false,
      reuse_values?: true,
      context: Map.take(query.context, [:shared])
    )
  end

  defp load_related(rows, _query), do: {:ok, rows}

  # `Ash.Filter.Runtime` loads a relationship the filter reaches with `Ash.load/3`, which reselects the source attribute
  # (`paddock_id`) from the data layer without running the read hooks, so a record whose foreign key the branch changed
  # would be judged by the database's. Loading it first with `reuse_values?: true`, which skips the reselect, goes
  # through the patched reads and leaves the runtime a loaded relationship to use.
  # An aggregate in a filter or sort is computed by the data layer from the base rows, which a record from the overlay
  # is not (the runtime would load it from the database and find nothing), and a record whose related rows the branch
  # changed would carry the database's number. The aggregates are computed over the branch first (`Aggregates.apply/3`),
  # and the runtime then finds them loaded.
  defp load_aggregates(records, aggregates, _query, _id) when map_size(aggregates) == 0,
    do: {:ok, records}

  defp load_aggregates(records, aggregates, query, id),
    do: Aggregates.apply(records, %{query | aggregates: aggregates}, id)

  defp load_for_filter(records, filter, query) do
    case Related.loads(filter) do
      [] ->
        {:ok, records}

      load ->
        Ash.load(records, load,
          domain: query.domain,
          tenant: query.tenant,
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
