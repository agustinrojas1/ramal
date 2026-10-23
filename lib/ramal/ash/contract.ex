defmodule Ramal.Ash.Contract do
  @moduledoc false
  # The Ash contract as data (ADR 0049). Each entry is an assumption Ramal relies on, with the feature it serves, the
  # tripwire test that checks it against Ash in CI, and a check that runs the same assumption on the host's Ash through
  # the probe resources in `Ramal.Ash.Probe`. The checks are the runtime half of the tripwires: a broken core assumption
  # refuses every branch read and write (`ensure/1`), and a broken extended one refuses only its feature.
  #
  # This file names Ash internals on purpose, as lib/ramal/ash/ is the one place outside `Ramal.Ash` allowed to
  # (test/ramal/ash_seam_test.exs). Each check returns `:ok` or `{:error, message}`; an exception or an exit is a broken
  # assumption too, so a check never takes the caller down.

  require Ash.Query
  require Logger

  alias Ramal.Ash.Probe.{Cow, Domain, Note, Ordered, Pasture, Plot, Report, Roll}
  alias Ramal.Error

  @broken_key {__MODULE__, :broken}
  @check_timeout 10_000

  @typedoc "The id of an assumption, as the doctor and the telemetry name it."
  @type id :: atom
  @type tier :: :core | :extended
  @type feature :: :core | :bulk | :upsert | :relationship_pages
  @type outcome :: :ok | {:broken, String.t()} | :not_checked

  @doc false
  @spec assumptions() :: [map]
  def assumptions do
    [
      # Core: a branch's single-record writes and patched reads depend on these.
      entry(
        :set_result_create,
        :core,
        :core,
        "a set_result in a before_action skips the data layer on create",
        "assumption: Ash.Changeset.set_result/2 in a before_action skips the data layer on create",
        &check_set_result_create/0
      ),
      entry(
        :set_result_update,
        :core,
        :core,
        "a set_result in a before_action skips the data layer on update",
        "assumption: Ash.Changeset.set_result/2 in a before_action skips the data layer on update",
        &check_set_result_update/0
      ),
      entry(
        :set_result_destroy,
        :core,
        :core,
        "a set_result in a before_action skips the data layer on destroy",
        "assumption: Ash.Changeset.set_result/2 in a before_action skips the data layer on destroy",
        &check_set_result_destroy/0
      ),
      entry(
        :global_change_after_action,
        :core,
        :core,
        "a global change runs after the action's own change",
        "assumption: a global change declared on the resource runs after the action's own change",
        &check_global_change_after_action/0
      ),
      entry(
        :not_atomic_update,
        :core,
        :core,
        "a change answering {:not_atomic, _} runs its change/3 and hooks on update",
        "assumption: an update whose change returns {:not_atomic, _} from atomic/3 runs change/3 and its hooks when require_atomic? is false",
        &check_not_atomic_update/0
      ),
      entry(
        :not_atomic_destroy,
        :core,
        :core,
        "a change answering {:not_atomic, _} runs its change/3 and hooks on destroy",
        "assumption: a destroy whose change returns {:not_atomic, _} from atomic/3 runs change/3 and its hooks when require_atomic? is false",
        &check_not_atomic_destroy/0
      ),
      entry(
        :set_result_page,
        :core,
        :core,
        "a set_result in a before_action of a paginated read is its page, and full_count its count",
        "assumption: a set_result in a before_action of a paginated read becomes the page's results, and full_count its count",
        &check_set_result_page/0
      ),
      entry(
        :atomic_bulk_refused,
        :core,
        :core,
        "an atomic bulk update of a query with a before_action hook is refused",
        "assumption: Ash refuses an atomic bulk update of a query that has a before_action hook",
        &check_atomic_bulk_refused/0
      ),
      entry(
        :stream_bulk_before_transaction,
        :core,
        :core,
        "a streamed bulk update runs the query's before_transaction hook and the before_action it adds",
        "assumption: a bulk update with strategy :stream runs a query's before_transaction hook and the before_action it adds",
        &check_stream_bulk_before_transaction/0
      ),
      entry(
        :accessing_from,
        :core,
        :core,
        "a relationship read's query names its source and relationship in context.accessing_from",
        "assumption: a relationship read's query has context.accessing_from naming the source and the relationship",
        &check_accessing_from/0
      ),
      entry(
        :private_actor,
        :core,
        :core,
        "a changeset's context.private.actor is the actor the action was given",
        "assumption: a changeset's context.private.actor is the actor passed to the action",
        &check_private_actor/0
      ),
      entry(
        :private_authorize,
        :core,
        :core,
        "a query run with authorize?: false has context.private.authorize? false",
        "assumption: a query run with authorize?: false has context.private.authorize? == false",
        &check_private_authorize/0
      ),
      entry(
        :query_fields,
        :core,
        :core,
        "Ash.Query has the hook and page fields Ramal rebuilds a query with",
        "assumption: Ash.Query has the fields Ramal rebuilds a query with",
        &check_query_fields/0
      ),
      entry(
        :unpaginated_read,
        :core,
        :core,
        "Ash.Actions.Read.unpaginated_read/3 returns every row when the read's default_limit is lower",
        "assumption: Ash.Actions.Read.unpaginated_read/3 returns every row when the read's default_limit is lower",
        &check_unpaginated_read/0
      ),
      entry(
        :export_runtime_sort,
        :core,
        :core,
        "Ash.Sort.runtime_sort/3 is exported",
        "assumption: Ash.Sort.runtime_sort/3 is exported (Ramal calls it in lib/ramal/collation.ex; from deps/ash/lib/ash/sort/sort.ex)",
        fn -> exported(Ash.Sort, :runtime_sort, 3) end
      ),
      entry(
        :export_sorting_on_identity,
        :core,
        :core,
        "Ash.Actions.Sort.sorting_on_identity?/1 is exported",
        "assumption: Ash.Actions.Sort.sorting_on_identity?/1 is exported (Ramal calls it in lib/ramal/preparation/paged.ex; from deps/ash/lib/ash/actions/sort.ex)",
        fn -> exported(Ash.Actions.Sort, :sorting_on_identity?, 1) end
      ),
      entry(
        :export_list_refs,
        :core,
        :core,
        "Ash.Filter.list_refs/4 is exported",
        "assumption: Ash.Filter.list_refs/4 is exported (Ramal calls it in lib/ramal/preparation/related.ex; from deps/ash/lib/ash/filter/filter.ex)",
        fn -> exported(Ash.Filter, :list_refs, 4) end
      ),
      entry(
        :export_filter_map,
        :core,
        :core,
        "Ash.Filter.map/2 is exported",
        "assumption: Ash.Filter.map/2 is exported (Ramal calls it in lib/ramal/preparation/related.ex; from deps/ash/lib/ash/filter/filter.ex)",
        fn -> exported(Ash.Filter, :map, 2) end
      ),
      entry(
        :export_hydrate_refs,
        :core,
        :core,
        "Ash.Filter.hydrate_refs/2 is exported",
        "assumption: Ash.Filter.hydrate_refs/2 is exported (Ramal calls it in lib/ramal/preparation/related.ex; from deps/ash/lib/ash/filter/filter.ex)",
        fn -> exported(Ash.Filter, :hydrate_refs, 2) end
      ),
      entry(
        :export_do_filter,
        :core,
        :core,
        "Ash.Query.do_filter/2 is exported",
        "assumption: Ash.Query.do_filter/2 is exported (Ramal calls it in lib/ramal/capture.ex; from deps/ash/lib/ash/query/query.ex)",
        fn -> exported(Ash.Query, :do_filter, 2) end
      ),
      entry(
        :export_filter_matches,
        :core,
        :core,
        "Ash.Filter.Runtime.filter_matches/4 is exported",
        "assumption: Ash.Filter.Runtime.filter_matches/4 is exported (Ramal calls it in lib/ramal/preparation.ex; from deps/ash/lib/ash/filter/runtime.ex)",
        fn -> exported(Ash.Filter.Runtime, :filter_matches, 4) end
      ),

      # Extended, :bulk: the record-by-record path of the bulk actions.
      entry(
        :bulk_create_around,
        :extended,
        :bulk,
        "an around_action hook runs once per record of a bulk create",
        "assumption: a bulk create runs an around_action hook once per record",
        &check_bulk_create_around/0
      ),
      entry(
        :bulk_update_around,
        :extended,
        :bulk,
        "an around_action hook runs once per record of a streamed bulk update",
        "assumption: a bulk update with strategy :stream runs an around_action hook once per record",
        &check_bulk_update_around/0
      ),
      entry(
        :bulk_destroy_around,
        :extended,
        :bulk,
        "an around_action hook runs once per record of a streamed bulk destroy",
        "assumption: a bulk destroy with strategy :stream runs an around_action hook once per record",
        &check_bulk_destroy_around/0
      ),
      entry(
        :bulk_update_query_for,
        :extended,
        :bulk,
        "a bulk update of a query reads with context.query_for :bulk_update",
        "assumption: a bulk update of a query reads with context.query_for == :bulk_update",
        &check_bulk_update_query_for/0
      ),
      entry(
        :bulk_destroy_query_for,
        :extended,
        :bulk,
        "a bulk destroy of a query reads with context.query_for :bulk_destroy",
        "assumption: a bulk destroy of a query reads with context.query_for == :bulk_destroy",
        &check_bulk_destroy_query_for/0
      ),
      entry(
        :bulk_context_markers,
        :extended,
        :bulk,
        "a bulk changeset's context carries bulk_create, bulk_update or bulk_destroy",
        "assumption: a bulk changeset's context carries bulk_create, bulk_update or bulk_destroy in change/3",
        &check_bulk_context_markers/0
      ),

      # Extended, :upsert: the upsert keys that change/3 reads from context.private.
      entry(
        :upsert_flag,
        :extended,
        :upsert,
        "change/3 of an upsert sees context.private.upsert? true",
        "assumption: in change/3 an action with upsert? true sees context.private.upsert? == true",
        &check_upsert_flag/0
      ),
      entry(
        :upsert_plain_create,
        :extended,
        :upsert,
        "change/3 of a plain create does not see an upsert",
        "assumption: in change/3 a plain create does not see context.private.upsert? == true",
        &check_upsert_plain_create/0
      ),
      entry(
        :upsert_for_create_option,
        :extended,
        :upsert,
        "the upsert?: true option of for_create/4 reaches change/3",
        "assumption: for_create/4 with upsert?: true sets context.private.upsert? in change/3",
        &check_upsert_for_create_option/0
      ),
      entry(
        :upsert_identity_fields,
        :extended,
        :upsert,
        "change/3 of an upsert sees its identity and fields",
        "assumption: in change/3 an upsert sees its upsert_identity and upsert_fields in context.private",
        &check_upsert_identity_fields/0
      ),
      entry(
        :upsert_condition,
        :extended,
        :upsert,
        "change/3 of an upsert with a condition sees the condition",
        "assumption: in change/3 an upsert with an upsert_condition sees it in context.private.upsert_condition",
        &check_upsert_condition/0
      ),

      # Extended, :relationship_pages: the loads a branch walks over its rows (paged, lateral and many-to-many).
      entry(
        :lateral_join_source,
        :extended,
        :relationship_pages,
        "a has_many load with a limit reaches its read with the source records and tagged rows",
        "assumption: a has_many load with a query limit reaches the destination read with lateral_join_source and tagged rows",
        &check_lateral_join_source/0
      ),
      entry(
        :export_has_parent_expr,
        :extended,
        :relationship_pages,
        "Ash.Actions.Read.Relationships.has_parent_expr?/1 is exported",
        "assumption: Ash.Actions.Read.Relationships.has_parent_expr?/1 is exported (Ramal calls it in lib/ramal/preparation/lateral.ex; from deps/ash/lib/ash/actions/read/relationships.ex)",
        fn -> exported(Ash.Actions.Read.Relationships, :has_parent_expr?, 1) end
      )
    ]
  end

  # Ash.Actions.Read.Relationships.reselect is informational: Ash.load/3 reselects a source attribute without the read
  # preparations, which is Ramal.load/3's reason to exist (ADR 0031). Nothing refuses on it, so it is not listed here.

  @doc false
  @spec run() :: [{id, outcome}]
  def run do
    for assumption <- assumptions(), do: {assumption.id, outcome(assumption)}
  end

  @doc false
  @spec broken() :: [id]
  def broken, do: :persistent_term.get(@broken_key, [])

  @doc false
  @spec put_broken([id]) :: :ok
  def put_broken(ids) when is_list(ids) do
    :persistent_term.put(@broken_key, ids)
  end

  @doc """
  The error a feature refuses with, when a core assumption or one of the feature's is broken on this Ash, or `:ok`.

  Called by `Ramal.Capture` and `Ramal.Preparation` on every write and read inside a branch. With nothing broken it is
  one `:persistent_term` read.
  """
  @spec ensure(feature) :: :ok | {:error, Error.t()}
  def ensure(feature) do
    case broken() do
      [] -> :ok
      ids -> refuse(feature, ids)
    end
  end

  defp refuse(feature, ids) do
    broken = Enum.filter(assumptions(), &(&1.id in ids))

    # A core assumption refuses every feature; an extended one refuses only its own.
    blocking =
      Enum.find(broken, &(&1.tier == :core)) ||
        if(feature == :core, do: nil, else: Enum.find(broken, &(&1.feature == feature)))

    case blocking do
      nil ->
        :ok

      %{id: id, summary: summary} ->
        version = Ramal.Ash.installed_version(:ash) || "not loaded"

        {:error,
         Error.new(
           :ash_incompatible,
           "Ramal refuses #{describe(feature)} on Ash #{version}: the Ash assumption \"#{summary}\" (#{id}) is broken " <>
             "on this version. Run `mix ramal.doctor` to see every check.",
           %{assumption: id, ash: version, feature: feature}
         )}
    end
  end

  defp describe(:core), do: "branch reads and writes"
  defp describe(:bulk), do: "bulk actions in a branch"
  defp describe(:upsert), do: "upserts in a branch"
  defp describe(:relationship_pages), do: "lateral relationship loads in a branch"

  @doc false
  @spec outcome(map) :: outcome
  def outcome(%{check: :tripwire_only}), do: :not_checked

  def outcome(%{check: check}) do
    ref = make_ref()
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        # The ETS data layer logs each write of a probe at debug (lib/ash/data_layer/ets/ets.ex). A check's writes are not
        # the host's log, so the check process logs at warning only.
        Logger.put_process_level(self(), :warning)
        send(parent, {ref, safely(check)})
      end)

    receive do
      {^ref, :ok} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {^ref, {:error, message}} ->
        Process.demonitor(monitor, [:flush])
        {:broken, message}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:broken, "the check exited: #{Exception.format_exit(reason)}"}
    after
      @check_timeout ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        {:broken, "the check did not finish in #{div(@check_timeout, 1000)} seconds"}
    end
  end

  # The check runs in a process of its own: the probe resources keep their rows in a table private to the process, so a
  # check leaves nothing behind, and it cannot see the rows of the host or of another check.
  defp safely(check) do
    check.()
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end

  defp entry(id, tier, feature, summary, tripwire, check) do
    %{id: id, tier: tier, feature: feature, summary: summary, tripwire: tripwire, check: check}
  end

  # Helpers for the checks. A check returns :ok or {:error, message}; an Ash call that fails outright raises, which the
  # runner reports as broken with Ash's message.

  defp expect(true, _message), do: :ok
  defp expect(_false, message), do: {:error, message}

  defp ok!({:ok, value}), do: value
  defp ok!(:ok), do: :ok
  defp ok!({:error, error}), do: raise(Exception.message(error))

  # A probe context: the hooks of the action send their reports to this process, tagged with `ref`.
  defp probe_context do
    ref = make_ref()
    {ref, %{ramal_probe: {self(), ref}}}
  end

  # The reports the probes sent for `ref`, in order. Ash returns after its hooks have run, and a stream's tasks have
  # sent theirs by then, so they are all here.
  defp reports(ref, acc \\ []) do
    receive do
      {^ref, message} -> reports(ref, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The changeset a probe change reported for `tag` in change/3.
  defp recorded(messages, tag) do
    case for({:recorded, ^tag, changeset} <- messages, do: changeset) do
      [changeset | _] -> changeset
      [] -> raise "the change of #{inspect(tag)} did not run"
    end
  end

  defp exported(module, function, arity) do
    Code.ensure_loaded(module)

    expect(
      function_exported?(module, function, arity),
      "#{inspect(module)}.#{function}/#{arity} is not exported by this Ash"
    )
  end

  # Writes

  defp check_set_result_create do
    {ref, context} = probe_context()

    record =
      Ash.create!(Note, %{title: "written"},
        action: :hooked_create,
        context: context,
        authorize?: false
      )

    messages = reports(ref)

    with :ok <-
           expect(
             record.title == "from the hook",
             "the create returned what the data layer would have, not the result its before_action set"
           ),
         :ok <-
           expect(
             :after_action_ran in messages,
             "the after_action hook did not run after a before_action set a result"
           ) do
      expect(
        Ash.read!(Note, authorize?: false) == [],
        "a create whose before_action set a result wrote the data layer"
      )
    end
  end

  defp check_set_result_update do
    row = Ash.create!(Note, %{title: "original"}, authorize?: false)
    {ref, context} = probe_context()

    record =
      Ash.update!(row, %{title: "written"},
        action: :hooked_update,
        context: context,
        authorize?: false
      )

    messages = reports(ref)

    with :ok <-
           expect(
             record.title == "from the hook",
             "the update did not return its before_action's result"
           ),
         :ok <-
           expect(
             :after_action_ran in messages,
             "the after_action hook did not run after a set result"
           ) do
      expect(
        Ash.get!(Note, row.id, authorize?: false).title == "original",
        "an update whose before_action set a result wrote the data layer"
      )
    end
  end

  defp check_set_result_destroy do
    row = Ash.create!(Note, %{title: "kept"}, authorize?: false)
    {ref, context} = probe_context()

    ok!(
      Ash.destroy(row,
        action: :hooked_destroy,
        return_destroyed?: true,
        context: context,
        authorize?: false
      )
    )

    messages = reports(ref)

    with :ok <-
           expect(
             :after_action_ran in messages,
             "the after_action hook did not run after a set result"
           ) do
      expect(
        match?({:ok, _}, Ash.get(Note, row.id, authorize?: false)),
        "a destroy whose before_action set a result removed the row from the data layer"
      )
    end
  end

  defp check_global_change_after_action do
    {ref, context} = probe_context()

    Ash.create!(Ordered, %{name: "order"},
      action: :with_own_change,
      context: context,
      authorize?: false
    )

    expect(
      reports(ref) == [{:mark, :action}, {:mark, :global}],
      "a global change ran before the action's own change, or not at all"
    )
  end

  defp check_not_atomic_update do
    row = Ash.create!(Note, %{title: "before"}, authorize?: false)
    {ref, context} = probe_context()

    updated =
      Ash.update!(row, %{}, action: :not_atomic_update, context: context, authorize?: false)

    messages = reports(ref)

    with :ok <-
           expect(
             updated.title == "changed by the change",
             "the update did not keep the change of its change/3"
           ),
         :ok <-
           expect(
             {:change, :update} in messages and {:before_action, :update} in messages,
             "a change answering {:not_atomic, _} did not run its change/3 and its hook on update"
           ) do
      expect(
        Ash.get!(Note, row.id, authorize?: false).title == "changed by the change",
        "the update of a change answering {:not_atomic, _} did not reach the data layer"
      )
    end
  end

  defp check_not_atomic_destroy do
    row = Ash.create!(Note, %{title: "gone"}, authorize?: false)
    {ref, context} = probe_context()

    ok!(Ash.destroy(row, action: :not_atomic_destroy, context: context, authorize?: false))
    messages = reports(ref)

    with :ok <-
           expect(
             {:change, :destroy} in messages and {:before_action, :destroy} in messages,
             "a change answering {:not_atomic, _} did not run its change/3 and its hook on destroy"
           ) do
      expect(
        match?({:error, _}, Ash.get(Note, row.id, authorize?: false)),
        "the destroy of a change answering {:not_atomic, _} did not reach the data layer"
      )
    end
  end

  defp check_atomic_bulk_refused do
    row = Ash.create!(Note, %{title: "atomic"}, authorize?: false)

    query =
      Note
      |> Ash.Query.filter(id == ^row.id)
      |> Ash.Query.before_action(& &1)

    result =
      Ash.bulk_update(query, :update, %{title: "renamed"},
        strategy: [:atomic],
        authorize?: false,
        return_errors?: true
      )

    message = Enum.map_join(result.errors, "\n", &Exception.message/1)

    with :ok <-
           expect(
             result.status == :error,
             "an atomic bulk update of a query with a before_action hook ran"
           ) do
      expect(
        message =~ "cannot atomically update a query if it has `before_action` hooks",
        "the atomic bulk update was refused for another reason: #{message}"
      )
    end
  end

  defp check_stream_bulk_before_transaction do
    row = Ash.create!(Note, %{title: "stream"}, authorize?: false)
    {ref, context} = probe_context()

    query =
      Note
      |> Ash.Query.filter(id == ^row.id)
      |> Ash.Query.set_context(context)
      |> Ash.Query.before_transaction(fn query ->
        Report.tell(query.context, :before_transaction_ran)

        Ash.Query.before_action(query, fn query ->
          Report.tell(query.context, :installed_before_action_ran)
          query
        end)
      end)

    result =
      Ash.bulk_update(query, :update, %{title: "streamed"},
        strategy: [:stream],
        authorize?: false,
        return_errors?: true
      )

    messages = reports(ref)

    with :ok <- expect(result.status == :success, "the streamed bulk update failed"),
         :ok <-
           expect(
             :before_transaction_ran in messages,
             "the streamed bulk update did not run the query's before_transaction hook"
           ) do
      expect(
        :installed_before_action_ran in messages,
        "the streamed bulk update did not run the before_action hook its before_transaction added"
      )
    end
  end

  # Reads

  defp check_set_result_page do
    rows = for n <- 1..3, do: Ash.create!(Roll, %{n: n}, authorize?: false)

    page =
      Ash.read!(Roll,
        action: :cut,
        page: [limit: 2, count: true],
        context: %{fixture: rows},
        authorize?: false
      )

    with :ok <-
           expect(
             Enum.map(page.results, & &1.id) == rows |> Enum.take(2) |> Enum.map(& &1.id),
             "the page of a paginated read is not the result its before_action set"
           ),
         :ok <-
           expect(page.more?, "the page of a paginated read does not say there are more rows") do
      expect(
        page.count == 7,
        "the full count of a paginated read is not the one its before_action set"
      )
    end
  end

  defp check_accessing_from do
    pasture = Ash.create!(Pasture, %{name: "accessing"}, authorize?: false)
    Ash.create!(Cow, %{name: "accessing", paddock_id: pasture.id}, authorize?: false)
    {ref, context} = probe_context()

    Ash.load!(pasture, [cows: Ash.Query.set_context(Ash.Query.new(Cow), context)],
      authorize?: false
    )

    queries = for {:query, query} <- reports(ref), do: query

    expect(
      Enum.any?(queries, &match?(%{source: Pasture, name: :cows}, Ramal.Ash.accessing_from(&1))),
      "the relationship read does not name its source and relationship in context.accessing_from"
    )
  end

  defp check_private_actor do
    {ref, context} = probe_context()

    Ash.Changeset.for_create(Plot, :plain, %{name: "actor", size: 1},
      actor: %{id: 7},
      context: context
    )

    expect(
      Ramal.Ash.actor(recorded(reports(ref), :plain)) == %{id: 7},
      "the changeset's context.private.actor is not the actor the action was given"
    )
  end

  defp check_private_authorize do
    {ref, context} = probe_context()
    Ash.read!(Note, authorize?: false, context: context)

    queries = for {:query, query} <- reports(ref), do: query

    expect(
      Enum.any?(queries, &(Ramal.Ash.authorize_opts(&1) == [authorize?: false])),
      "a query run with authorize?: false does not have context.private.authorize? == false"
    )
  end

  defp check_query_fields do
    query = Ramal.Ash.without_hooks(Ash.Query.new(Note))

    fields = [
      :before_action,
      :after_action,
      :before_transaction,
      :after_transaction,
      :around_transaction,
      :load,
      :calculations,
      :page,
      :limit,
      :offset,
      :context
    ]

    with :ok <-
           expect(
             Enum.all?(fields, &Map.has_key?(query, &1)),
             "Ash.Query has no one of the fields Ramal rebuilds a query with"
           ) do
      expect(query.before_action == [], "without_hooks left a before_action hook on the query")
    end
  end

  defp check_unpaginated_read do
    for n <- 1..3, do: Ash.create!(Roll, %{n: n}, authorize?: false)

    rows = ok!(Ramal.Ash.unpaginated_read(Ash.Query.new(Roll), authorize?: false, domain: Domain))

    expect(length(rows) == 3, "the unpaginated read returned #{length(rows)} rows of 3")
  end

  # Bulk

  defp check_bulk_create_around do
    {ref, context} = probe_context()

    result =
      Ash.bulk_create([%{title: "a"}, %{title: "b"}, %{title: "c"}], Note, :around_create,
        authorize?: false,
        return_errors?: true,
        context: context
      )

    with :ok <- expect(result.status == :success, "the bulk create failed") do
      expect(
        Enum.count(reports(ref), &(&1 == :around_action)) == 3,
        "the around_action hook of a bulk create did not run once per record"
      )
    end
  end

  defp check_bulk_update_around do
    rows = for n <- 1..3, do: Ash.create!(Note, %{title: "row #{n}"}, authorize?: false)
    {ref, context} = probe_context()

    result =
      Ash.bulk_update(rows, :around_update, %{title: "renamed"},
        strategy: [:stream],
        authorize?: false,
        return_errors?: true,
        context: context
      )

    with :ok <- expect(result.status == :success, "the streamed bulk update failed") do
      expect(
        Enum.count(reports(ref), &(&1 == :around_action)) == 3,
        "the around_action hook of a streamed bulk update did not run once per record"
      )
    end
  end

  defp check_bulk_destroy_around do
    rows = for n <- 1..3, do: Ash.create!(Note, %{title: "row #{n}"}, authorize?: false)
    {ref, context} = probe_context()

    result =
      Ash.bulk_destroy(rows, :around_destroy, %{},
        strategy: [:stream],
        authorize?: false,
        return_errors?: true,
        context: context
      )

    with :ok <- expect(result.status == :success, "the streamed bulk destroy failed") do
      expect(
        Enum.count(reports(ref), &(&1 == :around_action)) == 3,
        "the around_action hook of a streamed bulk destroy did not run once per record"
      )
    end
  end

  defp check_bulk_update_query_for do
    Ash.create!(Note, %{title: "query for"}, authorize?: false)
    {ref, context} = probe_context()

    Note
    |> Ash.Query.filter(title == "query for")
    |> Ash.Query.set_context(context)
    |> Ash.bulk_update(:update, %{title: "renamed"},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true
    )

    queries = for {:query, query} <- reports(ref), do: query

    expect(
      Enum.any?(queries, &(Ramal.Ash.bulk_read_for(&1) == :bulk_update)),
      "a bulk update of a query does not read with context.query_for == :bulk_update"
    )
  end

  defp check_bulk_destroy_query_for do
    Ash.create!(Note, %{title: "query for destroy"}, authorize?: false)
    {ref, context} = probe_context()

    Note
    |> Ash.Query.filter(title == "query for destroy")
    |> Ash.Query.set_context(context)
    |> Ash.bulk_destroy(:destroy, %{},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true
    )

    queries = for {:query, query} <- reports(ref), do: query

    expect(
      Enum.any?(queries, &(Ramal.Ash.bulk_read_for(&1) == :bulk_destroy)),
      "a bulk destroy of a query does not read with context.query_for == :bulk_destroy"
    )
  end

  defp check_bulk_context_markers do
    {ref, context} = probe_context()

    Ash.bulk_create([%{title: "marked"}], Note, :recorded_create,
      authorize?: false,
      return_errors?: true,
      context: context
    )

    row = Ash.create!(Note, %{title: "to update"}, authorize?: false)

    Ash.bulk_update([row], :recorded_update, %{title: "updated"},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true,
      context: context
    )

    Ash.bulk_destroy([row], :recorded_destroy, %{},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true,
      context: context
    )

    marked =
      for {:recorded, tag, changeset} <- reports(ref), Ramal.Ash.bulk?(changeset), do: tag

    expect(
      Enum.sort(Enum.uniq(marked)) == [:create, :destroy, :update],
      "a bulk changeset's context does not carry bulk_create, bulk_update or bulk_destroy in change/3 (marked: #{inspect(marked)})"
    )
  end

  # Upserts

  defp check_upsert_flag do
    {ref, context} = probe_context()
    Ash.Changeset.for_create(Plot, :upsert, %{name: "upsert", size: 1}, context: context)

    expect(
      Ramal.Ash.upsert?(recorded(reports(ref), :upsert)),
      "change/3 of an upsert does not see context.private.upsert? == true"
    )
  end

  defp check_upsert_plain_create do
    {ref, context} = probe_context()
    Ash.Changeset.for_create(Plot, :plain, %{name: "plain", size: 1}, context: context)

    expect(
      Ramal.Ash.upsert?(recorded(reports(ref), :plain)) == false,
      "change/3 of a plain create sees an upsert"
    )
  end

  defp check_upsert_for_create_option do
    {ref, context} = probe_context()

    Ash.Changeset.for_create(Plot, :plain, %{name: "forced", size: 1},
      upsert?: true,
      context: context
    )

    expect(
      Ramal.Ash.upsert?(recorded(reports(ref), :plain)),
      "the upsert?: true option of for_create/4 does not reach change/3"
    )
  end

  defp check_upsert_identity_fields do
    {ref, context} = probe_context()
    Ash.Changeset.for_create(Plot, :upsert, %{name: "keys", size: 1}, context: context)
    changeset = recorded(reports(ref), :upsert)

    expect(
      Ramal.Ash.upsert_identity(changeset) == :unique_name and
        Ramal.Ash.upsert_fields(changeset) == [:size],
      "change/3 of an upsert does not see its upsert_identity and upsert_fields"
    )
  end

  defp check_upsert_condition do
    {ref, context} = probe_context()
    Ash.Changeset.for_create(Plot, :conditional, %{name: "condition", size: 1}, context: context)

    expect(
      Ramal.Ash.upsert_condition(recorded(reports(ref), :conditional)) != nil,
      "change/3 of an upsert with an upsert_condition does not see it"
    )
  end

  # Relationship pages

  defp check_lateral_join_source do
    pasture = Ash.create!(Pasture, %{name: "lateral"}, authorize?: false)

    for n <- 1..3,
        do: Ash.create!(Cow, %{name: "lateral #{n}", paddock_id: pasture.id}, authorize?: false)

    {ref, context} = probe_context()

    Ash.load!(pasture, [cows: Ash.Query.set_context(Ash.Query.limit(Cow, 2), context)],
      authorize?: false
    )

    messages = reports(ref)
    queries = for {:query, query} <- messages, do: query
    rows = for {:rows, rows} <- messages, do: rows

    case for(
           query <- queries,
           Ramal.Ash.lateral_load?(query),
           do: Ramal.Ash.lateral_source(query)
         ) do
      [{[source], path} | _] ->
        with :ok <-
               expect(
                 source.id == pasture.id and is_list(path),
                 "the lateral_join_source of a has_many load does not name its source record"
               ) do
          expect(
            rows != [] and Enum.all?(List.flatten(rows), &(Ramal.Ash.lateral_tag(&1) != nil)),
            "the rows of a has_many load with a limit are not tagged with their source"
          )
        end

      _none ->
        {:error, "a has_many load with a limit did not reach its read with a lateral_join_source"}
    end
  end
end
