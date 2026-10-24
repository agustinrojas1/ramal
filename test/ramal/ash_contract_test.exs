defmodule Ramal.AshContractTest do
  # Tripwires for the Ash internals that Ramal relies on, checked against Ash directly. Each test names the assumption,
  # the Ramal code that depends on it and the Ash source it was confirmed in (Ash 3.37.0). The resources are in
  # test/support/ash_contract.ex and none of them uses Ramal.Resource, so these pass or fail on Ash alone.
  #
  # A failure means Ash changed a behaviour that Ramal relies on: look at the Ramal code named in the comment above the
  # test before a wrong row is written. Some assumptions are the other way round, and a failure there means a Ramal
  # workaround may no longer be needed (the ones named "reselects" and "refuses").
  use Ramal.DataCase, async: false

  @moduletag :ash_contract

  require Ash.Query

  alias Ash.Actions.Read
  alias Ramal.AshContract.{Cow, Domain, Gated, Note, Ordered, Pasture, Plot, Report, Roll}
  alias Ramal.Test.Ets

  setup do
    # The hooks report to this process by name (Ramal.AshContract.Report), so reports from a task still reach it.
    Report.register()
    Enum.each([Note, Plot, Ordered, Roll, Gated], &Ets.reset/1)
    :ok
  end

  defp pasture!(name),
    do: Ash.create!(Pasture, %{name: name, capacity_head: 10}, authorize?: false)

  defp cow!(pasture, name, head),
    do: Ash.create!(Cow, %{name: name, head: head, paddock_id: pasture.id}, authorize?: false)

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  defp count_received(message) do
    receive do
      ^message -> 1 + count_received(message)
    after
      0 -> 0
    end
  end

  defp marks do
    receive do
      {:mark, tag} -> [tag | marks()]
    after
      0 -> []
    end
  end

  # 1. set_result/2 in a before_action (upstream: ash-project/ash#3069)

  # Ramal: lib/ramal/capture.ex write/4 (set_result). Ash: deps/ash/lib/ash/actions/create/create.ex (action_result).
  test "assumption: Ash.Changeset.set_result/2 in a before_action skips the data layer on create" do
    assert {:ok, record} =
             Ash.create(Note, %{title: "written"}, action: :hooked_create, authorize?: false)

    assert record.title == "from the hook"
    assert_received :after_action_ran
    assert Ash.read!(Note, authorize?: false) == []
  end

  # Ramal: lib/ramal/capture.ex write/4 (set_result). Ash: deps/ash/lib/ash/actions/update/update.ex (action_result).
  test "assumption: Ash.Changeset.set_result/2 in a before_action skips the data layer on update" do
    row = Ash.create!(Note, %{title: "original"}, authorize?: false)

    assert {:ok, record} =
             Ash.update(row, %{title: "written"}, action: :hooked_update, authorize?: false)

    assert record.title == "from the hook"
    assert_received :after_action_ran
    assert Ash.get!(Note, row.id, authorize?: false).title == "original"
  end

  # Ramal: lib/ramal/capture.ex write/4 (set_result). Ash: deps/ash/lib/ash/actions/destroy/destroy.ex (action_result).
  test "assumption: Ash.Changeset.set_result/2 in a before_action skips the data layer on destroy" do
    row = Ash.create!(Note, %{title: "kept"}, authorize?: false)

    assert {:ok, _record} =
             Ash.destroy(row, action: :hooked_destroy, authorize?: false, return_destroyed?: true)

    assert_received :after_action_ran
    assert {:ok, %Note{}} = Ash.get(Note, row.id, authorize?: false)
  end

  # 2. bulk actions run an around_action changeset one record at a time (upstream: ash-project/ash#3069)

  # Ramal: lib/ramal/capture.ex moduledoc (bulk actions). Ash: deps/ash/lib/ash/actions/helpers.ex split_and_run_simple/7.
  test "assumption: a bulk create runs an around_action hook once per record" do
    result =
      Ash.bulk_create([%{title: "a"}, %{title: "b"}, %{title: "c"}], Note, :around_create,
        authorize?: false,
        return_errors?: true
      )

    assert result.status == :success
    assert count_received(:around_action) == 3
  end

  # Ramal: lib/ramal/capture.ex moduledoc (bulk actions). Ash: deps/ash/lib/ash/actions/helpers.ex split_and_run_simple/7.
  test "assumption: a bulk update with strategy :stream runs an around_action hook once per record" do
    rows = for n <- 1..3, do: Ash.create!(Note, %{title: "row #{n}"}, authorize?: false)
    flush()

    result =
      Ash.bulk_update(rows, :around_update, %{title: "renamed"},
        strategy: [:stream],
        authorize?: false,
        return_errors?: true
      )

    assert result.status == :success
    assert count_received(:around_action) == 3
  end

  # Ramal: lib/ramal/capture.ex moduledoc (bulk actions). Ash: deps/ash/lib/ash/actions/helpers.ex split_and_run_simple/7.
  test "assumption: a bulk destroy with strategy :stream runs an around_action hook once per record" do
    rows = for n <- 1..3, do: Ash.create!(Note, %{title: "row #{n}"}, authorize?: false)
    flush()

    result =
      Ash.bulk_destroy(rows, :around_destroy, %{},
        strategy: [:stream],
        authorize?: false,
        return_errors?: true
      )

    assert result.status == :success
    assert count_received(:around_action) == 3
  end

  # Ramal: lib/ramal/ash.ex bulk?/1 (the marker of a bulk changeset, which Ramal.Capture refuses in a branch when a bulk
  # contract assumption is broken). Ash: deps/ash/lib/ash/actions/create/bulk.ex (put_context :bulk_create, ~l.894),
  # deps/ash/lib/ash/actions/destroy/bulk.ex (:bulk_destroy, ~l.1879), deps/ash/lib/ash/actions/update/bulk.ex (~l.2313).
  test "assumption: a bulk changeset's context carries bulk_create, bulk_update or bulk_destroy in change/3" do
    Ash.bulk_create([%{title: "marked"}], Note, :markers,
      authorize?: false,
      return_errors?: true
    )

    assert_received {:markers, [:bulk_create]}

    row = Ash.create!(Note, %{title: "to update"}, authorize?: false)

    Ash.bulk_update([row], :markers_update, %{title: "updated"},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true
    )

    assert_received {:markers, [:bulk_update]}

    Ash.bulk_destroy([row], :markers_destroy, %{},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true
    )

    assert_received {:markers, [:bulk_destroy]}

    Ash.create!(Note, %{title: "single"}, action: :markers, authorize?: false)
    assert_received {:markers, []}
  end

  # 3. the upsert flags that change/3 reads (upstream: ash-project/ash#3069)

  # Ramal: lib/ramal/capture.ex upsert?/1 (read in change/3). Ash: deps/ash/lib/ash/changeset/changeset.ex for_create (set_context private).
  test "assumption: in change/3 an action with upsert? true sees context.private.upsert? == true" do
    Ash.Changeset.for_create(Plot, :upsert, %{name: "upsert", size: 1})
    assert_received {:recorded, :upsert, private}
    assert private[:upsert?] == true
  end

  # Ramal: lib/ramal/capture.ex capture/3 and plan_upsert/2 (upsert_identity, upsert_fields). Ash: deps/ash/lib/ash/changeset/changeset.ex for_create.
  test "assumption: in change/3 an upsert sees its upsert_identity and upsert_fields in context.private" do
    Ash.Changeset.for_create(Plot, :upsert, %{name: "upsert", size: 1})
    assert_received {:recorded, :upsert, private}
    assert private[:upsert_identity] == :unique_name
    assert private[:upsert_fields] == [:size]
  end

  # Ramal: lib/ramal/capture.ex capture/3 (refuses an upsert_condition). Ash: deps/ash/lib/ash/changeset/changeset.ex for_create.
  test "assumption: in change/3 an upsert with an upsert_condition sees it in context.private.upsert_condition" do
    Ash.Changeset.for_create(Plot, :conditional, %{name: "conditional", size: 1})
    assert_received {:recorded, :conditional, private}
    refute is_nil(private[:upsert_condition])
  end

  # Ramal: lib/ramal/capture.ex upsert?/1 (a plain create must not look like an upsert). Ash: deps/ash/lib/ash/changeset/changeset.ex for_create.
  test "assumption: in change/3 a plain create does not see context.private.upsert? == true" do
    Ash.Changeset.for_create(Plot, :plain, %{name: "plain", size: 1})
    assert_received {:recorded, :plain, private}
    refute private[:upsert?] == true
    assert private[:upsert_identity] == nil
  end

  # Ramal: lib/ramal/ash.ex touch_update_defaults?/1, read by Ramal.Capture in the write hook of an upsert
  # (plan_upsert/2), which runs as a before_action, after Ash has set the key. Ash:
  # deps/ash/lib/ash/actions/create/create.ex (do_run/4, ~l.170, sets the key for every create from the
  # touch_update_defaults? option, default true).
  test "assumption: in a before_action an upsert with touch_update_defaults?: false sees context.private.touch_update_defaults? == false, and not false by default" do
    Ash.create!(Plot, %{name: "touch off", size: 1},
      action: :hooked_upsert,
      touch_update_defaults?: false,
      authorize?: false
    )

    assert_received {:before, :hooked_upsert, %{touch_update_defaults?: false}}

    Ash.create!(Plot, %{name: "touch on", size: 1}, action: :hooked_upsert, authorize?: false)

    assert_received {:before, :hooked_upsert, private}
    refute private[:touch_update_defaults?] == false
  end

  # Ramal: lib/ramal/capture.ex upsert?/1 (an upsert? true option given to for_create). Ash: deps/ash/lib/ash/changeset/changeset.ex for_create (opts[:upsert?]).
  test "assumption: for_create/4 with upsert?: true sets context.private.upsert? in change/3" do
    Ash.Changeset.for_create(Plot, :plain, %{name: "forced", size: 1}, upsert?: true)
    assert_received {:recorded, :plain, private}
    assert private[:upsert?] == true
  end

  # 4. atomic/3 returning {:not_atomic, reason}

  # Ramal: lib/ramal/capture.ex atomic/3 and lib/ramal/resource/transformer.ex allow_non_atomic/1. Ash: deps/ash/lib/ash/actions/update/update.ex (fully_atomic_changeset).
  test "assumption: an update whose change returns {:not_atomic, _} from atomic/3 runs change/3 and its hooks when require_atomic? is false" do
    row = Ash.create!(Note, %{title: "before"}, authorize?: false)
    flush()

    assert {:ok, updated} = Ash.update(row, %{}, action: :not_atomic_update, authorize?: false)
    assert updated.title == "changed by the change"
    assert_received {:change, :update}
    assert_received {:before_action, :update}
    assert Ash.get!(Note, row.id, authorize?: false).title == "changed by the change"
  end

  # Ramal: lib/ramal/resource/transformer.ex allow_non_atomic/1 (why require_atomic? is relaxed). Ash: deps/ash/lib/ash/actions/update/update.ex (MustBeAtomic).
  test "assumption: an update whose change returns {:not_atomic, _} fails with MustBeAtomic when require_atomic? is true" do
    row = Ash.create!(Note, %{title: "before"}, authorize?: false)

    assert {:error, error} =
             Ash.update(row, %{}, action: :strict_not_atomic_update, authorize?: false)

    assert Enum.any?(error.errors, &match?(%Ash.Error.Framework.MustBeAtomic{}, &1))
  end

  # Ramal: lib/ramal/capture.ex atomic/3 (destroy) and lib/ramal/resource/transformer.ex allow_non_atomic/1. Ash: deps/ash/lib/ash/actions/destroy/destroy.ex.
  test "assumption: a destroy whose change returns {:not_atomic, _} from atomic/3 runs change/3 and its hooks when require_atomic? is false" do
    row = Ash.create!(Note, %{title: "gone"}, authorize?: false)
    flush()

    assert :ok = Ash.destroy(row, action: :not_atomic_destroy, authorize?: false)
    assert_received {:change, :destroy}
    assert_received {:before_action, :destroy}
    assert {:error, _} = Ash.get(Note, row.id, authorize?: false)
  end

  # 5. global changes run after the action's own changes

  # Ramal: lib/ramal/capture.ex record_caller_changes/1 comment. Ash: deps/ash/lib/ash/changeset/changeset.ex run_action_changes/6 (action changes, then global).
  test "assumption: a global change declared on the resource runs after the action's own change" do
    Ash.create!(Ordered, %{name: "order"}, action: :with_own_change, authorize?: false)

    assert marks() == [:action, :global]
  end

  # 6. set_result and full_count in the last before_action of a paginated read

  # Ramal: lib/ramal/preparation.ex page/3 and put_full_count/3. Ash: deps/ash/lib/ash/actions/read/read.ex run_query/4 (action_result) and fetch_count/5 (full_count).
  test "assumption: a set_result in a before_action of a paginated read becomes the page's results, and full_count its count" do
    rows = for n <- 1..3, do: Ash.create!(Roll, %{n: n}, authorize?: false)

    page =
      Ash.read!(Roll,
        action: :cut,
        page: [limit: 2, count: true],
        context: %{fixture: rows},
        authorize?: false
      )

    assert Enum.map(page.results, & &1.id) == rows |> Enum.take(2) |> Enum.map(& &1.id)
    assert page.more?
    assert page.count == 7
  end

  # 7. a has_many load with a limit is a lateral join (AshPostgres only; upstream: ash-project/ash#3071)

  # Ramal: lib/ramal/preparation/paged.ex lateral_load?/1 and lib/ramal/preparation/lateral.ex. Ash: deps/ash/lib/ash/actions/read/relationships.ex lateral_join?/4 (~l.1880) and with_lateral_join_query/4 (~l.379).
  test "assumption: a has_many load with a query limit reaches the destination read with lateral_join_source and tagged rows" do
    pasture = pasture!("lateral")
    for n <- 1..3, do: cow!(pasture, "lateral #{n}", n)
    flush()

    Ash.load!(pasture, [cows: Ash.Query.limit(Cow, 2)], authorize?: false)

    assert_received {:probe, :before_action,
                     %{data_layer: %{lateral_join_source: {[source], path}}}}

    assert source.id == pasture.id
    assert is_list(path)

    assert_received {:probe, :rows, rows}
    assert rows != []
    assert Enum.all?(rows, &Map.has_key?(&1, :__lateral_join_source__))
  end

  # 8. Ash.load/3 reselects the source attribute without running the read hooks (upstream: ash-project/ash#3072)

  # Ramal: lib/ramal.ex load/3 (its doc: the reselect follows the database's foreign key). Ash: deps/ash/lib/ash/actions/read/read.ex reselect_and_load/6 (~l.1700).
  test "assumption: Ash.load/3 reselects a belongs_to source attribute without running the read hooks its preparations add (a failure here means Ramal.load/3's workaround may be unneeded)" do
    pasture = pasture!("reselect")
    cow = cow!(pasture, "reselect", 1)

    cow =
      Cow
      |> Ash.Query.select([:id, :name, :head])
      |> Ash.Query.filter(id == ^cow.id)
      |> Ash.read_one!(authorize?: false)

    refute Ash.Resource.selected?(cow, :paddock_id)
    flush()

    loaded = Ash.load!(cow, :pasture, authorize?: false)

    assert loaded.pasture.id == pasture.id
    refute_received {:probe, _, _}
  end

  # 9. an atomic bulk update of a query with hooks

  # Ramal: lib/ramal/preparation.ex prepare/3 (the comment on bind_late: a before_action hook refuses an atomic bulk update). Ash: deps/ash/lib/ash/actions/update/bulk.ex (the atomic check, ~l.101).
  test "assumption: Ash refuses an atomic bulk update of a query that has a before_action hook" do
    pasture = pasture!("atomic refusal")

    query =
      Pasture
      |> Ash.Query.filter(id == ^pasture.id)
      |> Ash.Query.before_action(& &1)

    result =
      Ash.bulk_update(query, :update, %{name: "renamed"},
        strategy: [:atomic],
        authorize?: false,
        return_errors?: true
      )

    assert result.status == :error
    assert [error] = result.errors

    assert Exception.message(error) =~
             "cannot atomically update a query if it has `before_action` hooks"
  end

  # Ramal: lib/ramal/preparation.ex prepare/3 and bind_late/1 (a query prepared outside a branch installs its hooks when run). Ash: deps/ash/lib/ash/actions/read/read.ex run_before_transaction_hooks/1 (reached through the stream read).
  test "assumption: a bulk update with strategy :stream runs a query's before_transaction hook and the before_action it adds" do
    pasture = pasture!("stream transaction hook")

    query =
      Pasture
      |> Ash.Query.filter(id == ^pasture.id)
      |> Ash.Query.before_transaction(fn query ->
        Report.tell(:before_transaction_ran)

        Ash.Query.before_action(query, fn query ->
          Report.tell(:installed_before_action_ran)
          query
        end)
      end)

    flush()

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_update(query, :update, %{name: "streamed"},
               strategy: [:stream],
               authorize?: false,
               return_errors?: true
             )

    assert_received :before_transaction_ran
    assert_received :installed_before_action_ran
  end

  # 10. context markers that Ramal reads (upstream: ash-project/ash#3071)

  # Ramal: lib/ramal/preparation/lateral.ex parent_expr?/1 (context.accessing_from). Ash: deps/ash/lib/ash/actions/read/relationships.ex (accessing_from, ~l.399 and ~l.756).
  test "assumption: a relationship read's query has context.accessing_from naming the source and the relationship" do
    pasture = pasture!("accessing")
    cow!(pasture, "accessing", 1)
    flush()

    Ash.load!(pasture, :cows, authorize?: false)

    assert_received {:probe, :before_action, %{accessing_from: %{source: Pasture, name: :cows}}}
  end

  # Ramal: lib/ramal/preparation/paged.ex unpaginated?/1 (context.query_for). Ash: deps/ash/lib/ash/actions/update/bulk.ex (query_for :bulk_update, ~l.82 and ~l.175).
  test "assumption: a bulk update of a query reads with context.query_for == :bulk_update" do
    pasture = pasture!("bulk update")
    cow!(pasture, "bulk update", 1)
    flush()

    Cow
    |> Ash.Query.filter(name == "bulk update")
    |> Ash.bulk_update(:update, %{head: 2},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true
    )

    assert_received {:probe, :before_action, %{query_for: :bulk_update}}
  end

  # Ramal: lib/ramal/preparation/paged.ex unpaginated?/1 (context.query_for). Ash: deps/ash/lib/ash/actions/destroy/bulk.ex (query_for :bulk_destroy, ~l.121).
  test "assumption: a bulk destroy of a query reads with context.query_for == :bulk_destroy" do
    pasture = pasture!("bulk destroy")
    cow!(pasture, "bulk destroy", 1)
    flush()

    Cow
    |> Ash.Query.filter(name == "bulk destroy")
    |> Ash.bulk_destroy(:destroy, %{},
      strategy: [:stream],
      authorize?: false,
      return_errors?: true
    )

    assert_received {:probe, :before_action, %{query_for: :bulk_destroy}}
  end

  # Ramal: lib/ramal/capture.ex write/4 and entry (the actor of the changeset, changeset.context.private.actor). Ash: deps/ash/lib/ash/changeset/changeset.ex set_actor/2.
  test "assumption: a changeset's context.private.actor is the actor passed to the action" do
    Ash.Changeset.for_create(Plot, :plain, %{name: "actor", size: 1}, actor: %{id: 7})
    assert_received {:recorded, :plain, %{actor: %{id: 7}}}
  end

  # Ramal: lib/ramal/preparation/aggregates.ex opts/2 (context.private.authorize?). Ash: deps/ash/lib/ash/query/query.ex set_authorize?/2.
  test "assumption: a query run with authorize?: false has context.private.authorize? == false" do
    pasture = pasture!("authorize")
    cow!(pasture, "authorize", 1)
    flush()

    Ash.read!(Cow, authorize?: false)

    assert_received {:probe, :before_action, %{private: %{authorize?: false}}}
  end

  # 11. internal Ash functions that Ramal calls

  for {module, function, arity, ramal, ash} <- [
        # Ramal: lib/ramal/resource.ex read_all/2. Ash: deps/ash/lib/ash/actions/read/read.ex (unpaginated_read/3, l.18).
        {Ash.Actions.Read, :unpaginated_read, 3, "lib/ramal/resource.ex",
         "deps/ash/lib/ash/actions/read/read.ex"},
        # Ramal: lib/ramal/collation.ex and lib/ramal/aggregate.ex. Ash: deps/ash/lib/ash/sort/sort.ex (the public runtime_sort/3, delegated).
        {Ash.Sort, :runtime_sort, 3, "lib/ramal/collation.ex", "deps/ash/lib/ash/sort/sort.ex"},
        # Ramal: lib/ramal/preparation/paged.ex stable_sort/1. Ash: deps/ash/lib/ash/actions/sort.ex (sorting_on_identity?/1, l.49).
        {Ash.Actions.Sort, :sorting_on_identity?, 1, "lib/ramal/preparation/paged.ex",
         "deps/ash/lib/ash/actions/sort.ex"},
        # Ramal: lib/ramal/preparation/lateral.ex and many_to_many.ex. Ash: deps/ash/lib/ash/actions/read/relationships.ex (has_parent_expr?/1, l.1989).
        {Ash.Actions.Read.Relationships, :has_parent_expr?, 1, "lib/ramal/preparation/lateral.ex",
         "deps/ash/lib/ash/actions/read/relationships.ex"},
        # Ramal: lib/ramal/preparation/related.ex and lib/ramal/preparation.ex. Ash: deps/ash/lib/ash/filter/filter.ex (list_refs/5 with defaults, l.2775).
        {Ash.Filter, :list_refs, 4, "lib/ramal/preparation/related.ex",
         "deps/ash/lib/ash/filter/filter.ex"},
        # Ramal: lib/ramal/preparation/related.ex (filter rewriting). Ash: deps/ash/lib/ash/filter/filter.ex (map/2, l.1618).
        {Ash.Filter, :map, 2, "lib/ramal/preparation/related.ex",
         "deps/ash/lib/ash/filter/filter.ex"},
        # Ramal: lib/ramal/ash.ex (a merge refused inside the caller's transaction drops the notifications it queued). Ash: deps/ash/lib/ash/actions/helpers.ex (peek_queued_notifications/0).
        {Ash.Actions.Helpers, :peek_queued_notifications, 0, "lib/ramal/ash.ex",
         "deps/ash/lib/ash/actions/helpers.ex"},
        # Ramal: lib/ramal/ash.ex, as above. Ash: deps/ash/lib/ash/actions/helpers.ex (restore_queued_notifications/1).
        {Ash.Actions.Helpers, :restore_queued_notifications, 1, "lib/ramal/ash.ex",
         "deps/ash/lib/ash/actions/helpers.ex"},
        # Ramal: lib/ramal/preparation.ex and lib/ramal/preparation/related.ex. Ash: deps/ash/lib/ash/filter/runtime.ex (filter_matches/4, l.19).
        {Ash.Filter.Runtime, :filter_matches, 4, "lib/ramal/preparation.ex",
         "deps/ash/lib/ash/filter/runtime.ex"},
        # Ramal: lib/ramal/preparation/related.ex (refs of a rewritten filter). Ash: deps/ash/lib/ash/filter/filter.ex (hydrate_refs/2).
        {Ash.Filter, :hydrate_refs, 2, "lib/ramal/preparation/related.ex",
         "deps/ash/lib/ash/filter/filter.ex"},
        # Ramal: the keyset cursor and the key lookups of Ramal.Capture and Ramal.Merge. Ash: deps/ash/lib/ash/query/query.ex (do_filter/3, @doc false, opts defaulted).
        {Ash.Query, :do_filter, 2, "lib/ramal/capture.ex", "deps/ash/lib/ash/query/query.ex"},
        # Ramal: lib/ramal/ash.ex fragment?/1 (finds a fragment in a filter, ADR 0054). Ash: deps/ash/lib/ash/filter/filter.ex (flat_map/2, l.1699).
        {Ash.Filter, :flat_map, 2, "lib/ramal/ash.ex", "deps/ash/lib/ash/filter/filter.ex"}
      ] do
    test "assumption: #{inspect(module)}.#{function}/#{arity} is exported (Ramal calls it in #{ramal}; from #{ash})" do
      Code.ensure_loaded!(unquote(module))
      assert function_exported?(unquote(module), unquote(function), unquote(arity))
    end
  end

  # Ramal: lib/ramal/resource.ex read_all/2 (unpaginated_read/3 skips the action's paginate step). Ash: deps/ash/lib/ash/actions/read/read.ex (unpaginated_read/3, l.18). Upstream: ash-project/ash#3070.
  test "assumption: Ash.Actions.Read.unpaginated_read/3 returns every row when the read's default_limit is lower" do
    for n <- 1..3, do: Ash.create!(Roll, %{n: n}, authorize?: false)

    assert {:ok, rows} =
             Read.unpaginated_read(Ash.Query.new(Roll), nil, authorize?: false, domain: Domain)

    assert length(rows) == 3
  end

  # 12. the Ash.Query struct fields that Ramal rebuilds

  # Ramal: lib/ramal/preparation.ex read_whole_list/2 (the query fields it rebuilds). Ash: deps/ash/lib/ash/query/query.ex defstruct (l.160).
  test "assumption: Ash.Query has the fields Ramal rebuilds a query with" do
    keys = Map.keys(%Ash.Query{})

    for field <- [
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
        ] do
      assert field in keys, "Ash.Query has no #{inspect(field)} field"
    end
  end

  # 13. a read marked internal is exempt from the domain's actor requirement

  # Ramal: lib/ramal/collation.ex load/3 (Ramal.Ash.mark_internal/1, for the loads that sort by a calculation:
  # authorize?: false and no actor). Ash: deps/ash/lib/ash/actions/helpers.ex add_actor/3 and add_authorize?/3
  # (internal?/1, ~l.471-496).
  test "assumption: a read with context.private.internal? true is exempt from a domain's require_actor? and authorize: :always" do
    Ash.create!(Gated, %{name: "marked"}, actor: %{id: 1})
    marked = Ash.Query.set_context(Gated, %{private: %{internal?: true}})

    assert {:ok, [%Gated{name: "marked"}]} = Ash.read(marked, authorize?: false)

    assert_raise Ash.Error.Forbidden, fn -> Ash.read(Gated, authorize?: false) end
  end

  # 14. the pages of a stream are not cut to the action's max_page_size

  # Ramal: lib/ramal/ash.ex bypass_max_page_size?/1, read by lib/ramal/preparation/paged.ex limit/3 (the page size of
  # every paginated read in a branch) and unpaginated?/1 (the streamed source of a bulk action). Ash:
  # deps/ash/lib/ash/actions/read/stream.ex (do_stream/4 and the offset stream set the key on the page queries, ~l.40
  # and ~l.102), read.ex (clamp_page_limit/3, ~l.4093, which clamps unless the key is set).
  test "assumption: a streamed read's page queries carry context.private.bypass_max_page_size? true, and an ordinary read's do not" do
    Ash.create!(Cow, %{name: "stream pages", head: 1}, authorize?: false)
    flush()

    Cow |> Ash.stream!(authorize?: false) |> Enum.to_list()

    assert_received {:probe, :before_action, %{private: %{bypass_max_page_size?: true}}}

    flush()
    Ash.read!(Cow, authorize?: false)

    assert_received {:probe, :before_action, context}
    refute get_in(context, [:private, :bypass_max_page_size?])
  end
end
