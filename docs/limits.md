# Limits

Ramal is comprehensive, and every limit it has is listed here. Each line is one sentence and links to where the limit is explained in full. The reasons are in the [design document](DESIGN.md) and the [ADRs](adr/README.md).

## The list

- A branch cannot change the schema, add indexes, or promise a query plan, because it is not a database branch ([design, section 1](DESIGN.md)).
- `Ramal.run/2` cannot be nested, so a branch of a branch is a nested fork, run on its own and merged into its parent ([ADR 0043](adr/0043-nested-branches-merge-into-their-parent.md)).
- `Ramal.run/3` with `atomic: true` takes back the writes of a failed run but is not a transaction: it does not isolate (use it from one process at a time on a branch), it does not undo what `fun` did outside the branch, and on a durable branch a crash before the rollback's snapshot is stored brings the writes back ([ADR 0052](adr/0052-atomic-run-takes-back-a-failed-runs-writes.md)).
- A branch lives on one node unless you run a cluster with `cluster: true` on `Ramal.Supervisor` and the Postgres storage ([ADR 0044](adr/0044-branches-in-a-cluster.md)).
- In a cluster, a process that lost its branch in a netsplit is fenced at its next save, and unless the branch is durable what it held since its last save is lost and announced with `[:ramal, :branch, :fenced]` ([ADR 0044](adr/0044-branches-in-a-cluster.md)).
- In a cluster, telemetry, the `:branch_rate` window and the heap-kill marks stay on each node, so other nodes do not see them ([ADR 0044](adr/0044-branches-in-a-cluster.md)).
- An aggregate loaded in a branch is recomputed from the branch's rows, but a `custom` aggregate, a join filter or a custom read action keeps the database's value and emits `[:ramal, :read, :unpatched_aggregate]` ([ADR 0029](adr/0029-declared-aggregates-in-branches.md)).
- A filter or sort on an aggregate sees the branch, but when the branch changed a resource on the aggregate's path it reads every row the rest of the filter matches, and for one total over a large table `Ramal.aggregate/4` is cheaper ([ADR 0032](adr/0032-aggregate-filters-and-sorts.md), [ADR 0013](adr/0013-aggregate-delta.md)).
- A filter with a `fragment(...)` is judged by the database on the branch's rows, sent as an inline `VALUES` table, so it needs AshPostgres and one more query per read; it is refused with `:fragment_unsupported` on another data layer, on a table in a schema or a schema-per-tenant tenant, and when the same filter reaches a resource the branch changed, and a sort or a declared aggregate that holds a fragment is not covered ([ADR 0054](adr/0054-fragment-filters-judged-by-the-database.md)).
- `Ash.load/3` on a record the branch changed follows the database's foreign key, so use `Ramal.load/3`, and a load inside a read is patched ([ADR 0031](adr/0031-ramal-load.md)).
- A filter or sort through a relationship the branch changed can read more rows than it needs, so keep attribute predicates next to it ([ADR 0047](adr/0047-relationship-filter-narrowing.md), [ADR 0025](adr/0025-relationship-filters-in-elixir.md)).
- A filter through a `belongs_to` or `has_one` is narrowed in the database except under `not`, while `exists`, longer paths and `has_many` paths read every row the rest of the filter allows ([ADR 0047](adr/0047-relationship-filter-narrowing.md)).
- Text sorts inside a branch follow the database's collation, except a `C` column, a resource on another data layer and every key that is not text, which keep their own order, and a keyset cursor on a text sort and a comparison filter on text still compare bytes ([ADR 0045](adr/0045-text-sorted-by-the-databases-collation.md)).
- `Ramal.branch/2` refuses a domain with a resource that has write actions and neither uses `Ramal.Resource` nor sets `branchable? false`, and only the branch's domain is checked, so a resource of another domain is not covered ([ADR 0027](adr/0027-domain-coverage.md)).
- A changeset built under one branch and run under another, or outside a branch and run inside one, fails with `:branch_mismatch`, and a query prepared outside a branch is patched when it is read inside one ([ADR 0026](adr/0026-branch-checked-at-execution.md), [ADR 0028](adr/0028-late-binding-queries.md)).
- Only writes of `create`, `update` and `destroy` actions are held in a branch: a generic action and the outside effects of a hook (an HTTP call, an email, an Oban job, a `Repo` write) run for real, so such hooks should skip themselves when `Ramal.current/0` returns a branch or `Ramal.in_branch?/1` is true ([security notes](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md)).
- Raw Ecto and SQL queries on a branched table do not see a branch: inside `Ramal.run/2` they read and write the database. Nothing stops them, but `warn_raw_queries: true | :raise` on `Ramal.Supervisor` reports each one while you develop and test, and `mix ramal.doctor` lists the places that look like one ([details](#raw-ecto-queries-do-not-see-a-branch), [ADR 0053](adr/0053-raw-query-guard.md)).
- Notifications are dropped unless the resource opts in with `notify_in_branch? true` ([ADR 0005](adr/0005-write-capture.md)).
- A database-generated integer or UUID key is a placeholder until the merge renames it to the real key, and other key types, `smallint` keys and composite keys are refused ([ADR 0042](adr/0042-placeholder-keys-for-generated-primary-keys.md)). A sort or keyset page on a generated integer key puts those rows after every real key (before them for `:desc`), as the merge will; a UUID key has no creation order, so a sort by it gives the branch's new rows an arbitrary place until the merge, and a filter by comparison on a placeholder (`id > 5`) sees the negative number. Sort by an inserted timestamp when order matters for a UUID key.
- An upsert with an `upsert_condition` is refused, and `upsert?: true` given only to `Ash.create/2` at call time acts as a create ([ADR 0038](adr/0038-upserts-in-the-branch-view.md)), and a branch cannot do `ON CONFLICT DO NOTHING`, so "insert if missing, otherwise leave it alone" is a read then a plain create ([details](#insert-if-missing-otherwise-leave-it-alone)).
- A create or update in a branch is checked against the resource's identities in the branch's view, but an identity whose `where` cannot be evaluated in Elixir for the new row is left unchecked, an identity that spans tenants (`all_tenants? true`) is checked only inside the branch's tenant, and a row another writer adds to the database after the branch opened is found only by the merge.
- A discarded, merged or rejected branch keeps its record in storage until you remove it, so a host that opens branches as scratch space should use `Ramal.discard(branch, purge: true)` or `Ramal.delete/1` ([details](#throwaway-branches-leave-a-record-unless-you-purge-them)).
- A branch works in one tenant, given at `Ramal.branch/2` ([ADR 0034](adr/0034-one-tenant-per-branch.md)).
- Reads fetch candidate rows and patch them in memory, which is cheap for the rows a session touches and wrong for an analytics table, so Ramal is meant for OLTP-sized working sets ([design, section 4.1](DESIGN.md)).
- Merge replays each change through your action, so it is slower than one SQL statement, which is the price of merging through your own rules ([details](#merge-is-slower-than-sql)).
- Writes since the last save are lost if the node crashes, unless the branch is durable, and a durable branch costs one storage write per action ([ADR 0048](adr/0048-durable-branches.md), [details](#durable-branches-cost-a-write-per-action)).
- After a crash, the merge of a durable branch cannot see a database change to a row the branch read but did not write since its last save, while every row an action wrote keeps its fingerprint ([ADR 0048](adr/0048-durable-branches.md)).
- A custom Ash type must round-trip through `Ash.Type.dump_to_embedded/3` and `Ash.Type.cast_from_embedded/3`, because a branch stores its values that way, and a type that does not gives a branch a value other than the database's with no error ([details](#a-custom-type-must-round-trip-its-embedded-form)).
- Bulk actions run record by record in a branch, and a bulk update or destroy of a query must allow `strategy: [:atomic, :stream]` ([ADR 0036](adr/0036-bulk-actions-record-by-record.md)).
- On Ash 3.37 a `through` path with a many_to_many hop is left to the database, which returns nothing for it with or without a branch; Ash after 3.37 expands the hop and the branch sees it. A `through` path with a relationship filter, a limit on a hop, a `distinct` or a `parent` expression is left to the database too, so it shows the branch's changes to rows the database already has but not the rows it created ([ADR 0046](adr/0046-through-paths-walked-over-the-branch.md)).
- Authorization is yours, because anyone who holds a branch id can act on it and Ramal records who decided but never checks ([security notes](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md)).
- The public API may change before 1.0, and the changelog says when it does ([stability](STABILITY.md)).

## Details

### Merge is slower than SQL

Merge runs the replay in one transaction, and each change goes through your real action, so its validations, policies and hooks run again. In the published benchmark a replayed change costs about 0.4 ms, while one set-based `UPDATE` of the same rows is 15 to 64 times faster ([bench/README.md](https://github.com/agustinrojas1/ramal/blob/main/bench/README.md)). A database merge cannot apply your own rules, which is why Ramal pays this cost ([ADR 0007](adr/0007-merge.md)).

### Durable branches cost a write per action

With Postgres on the same host, appending one action's writes to the write log takes 1.1 to 1.7 ms in the published benchmark ([bench/README.md](https://github.com/agustinrojas1/ramal/blob/main/bench/README.md#durable-branches)). The action's own transaction holds a connection while the log is written over another, so the pool needs room for both. The SQL sandbox shares one connection and cannot run the append, so test durable branches with the ETS storage ([ADR 0048](adr/0048-durable-branches.md)).

### Raw Ecto queries do not see a branch

A branch holds the writes of Ash actions. `Repo.all(from p in "paddocks")`, `Repo.aggregate`, `update_all`, a join on a link
table or a fragment goes to the database, so inside `Ramal.run/2` it returns the base data, and a validation or a number
computed from it is wrong with no error. Two tools find them, both off by default:

- `{Ramal.Supervisor, repo: MyApp.Repo, warn_raw_queries: true}` (or `:raise`) attaches a handler to the repo's query
  event. A query that names the table of a branched resource of your `:ash_domains`, made by a process inside a branch
  (tasks it started included), emits `[:ramal, :raw_query, :detected]`, with the branch id, table, resource, SQL,
  `call_site` and `stacktrace` in the metadata. Ramal logs nothing: attach a handler that warns or logs where you want it.
  Ash actions, Ramal's own reads and the merge are not reported. Use it in development and test: it takes a stack trace
  for each such query.
- With `:raise`, `Ramal.run/2` also returns `{:error, %Ramal.Error{reason: :raw_query}}` once its function has returned,
  and `Ramal.run!/2` raises it. The query itself cannot be failed, because `:telemetry` detaches a handler that raises and
  the query has run by then; the branch's writes stay.
- `mix ramal.doctor` prints the lines of `lib/**/*.ex` that look like `from(x in <resource or its Ecto schema or table>)`
  or a `Repo` call on one. It is a regular expression over single lines: a query split across lines or built at runtime is
  missed, and the guard above is the check that sees what runs.

To log them, attach a handler in your application start (development and test):

```elixir
:telemetry.attach(
  "warn-raw-queries",
  [:ramal, :raw_query, :detected],
  fn _event, _measurements, meta, _config ->
    Logger.warning(
      "raw query on #{meta.table} inside branch #{meta.branch_id} at #{meta.call_site}\n" <>
        Exception.format_stacktrace(meta.stacktrace)
    )
  end,
  nil
)
```

Replace what they find with an Ash action, `Ramal.load/3` or `Ramal.aggregate/4` ([ADR 0053](adr/0053-raw-query-guard.md)).
### Throwaway branches leave a record unless you purge them

`Ramal.discard/1` stops the branch process and drops its overlay, but keeps the record in storage with status `:discarded`, so `Ramal.list/2` can show it and a later call gets `:not_open`. Merging or rejecting a branch keeps its record too. Nothing removes a record by itself, and one is about 1 KB in ETS, so a host that opens a branch (or a fork per step) for every request and discards it grows the storage, and slows `list/2`, without bound.

For a branch nobody will look at later, discard it with `Ramal.discard(branch, purge: true)`: the process stops and the record is deleted with its write log, in ETS and in Postgres storage. For a branch you kept for review and are done with, `Ramal.delete(branch)` removes the record of a `:discarded`, `:merged` or `:rejected` branch, and refuses an `:open` or `:proposed` one with `:not_terminal`. Both emit `[:ramal, :branch, :delete]`. Ramal does not sweep old records on a timer; a host that wants that calls `Ramal.list(domain, status: :discarded)` and `Ramal.delete/1` from its own job.

### Insert if missing, otherwise leave it alone

Ash has no `ON CONFLICT DO NOTHING`, and a branch cannot get close to it:

- In AshPostgres, `upsert? true` with `upsert_fields []` becomes `ON CONFLICT (...) DO UPDATE SET <identity columns> = EXCLUDED.<same>`, so a repeated insert still rewrites the existing row (a new tuple, WAL traffic, and any trigger on update fires). It does this so it can return the existing row (`fields_to_upsert` falls back to the identity keys in `deps/ash_postgres/lib/data_layer.ex`, AshPostgres 2.15).
- The usual way to make the update do nothing, an `upsert_condition` that is never true (`expr(false)`), is refused inside a branch with `:upsert_unsupported`, because the condition is a filter the database evaluates against the existing row ([ADR 0038](adr/0038-upserts-in-the-branch-view.md)).
- `upsert_fields []` is accepted in a branch. A repeat returns the existing row with its attributes unchanged, but it is recorded as an update that touches only the update timestamp, and the merge replays it.

The pattern that works in a branch and leaves an existing row alone is to read first and create only what is missing:

```elixir
case MyApp.Farm.Edge |> Ash.Query.filter(a == ^a and b == ^b) |> Ash.read_one!() do
  nil -> Ash.create!(MyApp.Farm.Edge, %{a: a, b: b})
  edge -> edge
end
```

Outside a concurrent writer this is exact. If another process may insert the same row, give the table a unique identity so the merge fails on the duplicate (`:merge_failed`) instead of writing it twice, or accept the no-op update of `upsert_fields []`, which is race-free and costs one rewritten row per repeat. These behaviours are pinned in `test/ramal/upsert_test.exs`.

### A custom type must round-trip its embedded form

A branch keeps attribute values in memory as Elixir terms, and the Postgres storage writes them as JSON through `Ash.Type.dump_to_embedded/3` and reads them back through `Ash.Type.cast_from_embedded/3`. A durable branch does the same for each action's write log. For a type you wrote with `use Ash.Type` those callbacks default to `dump_to_native/2` and `cast_stored/2`, and a `use Ash.Type.NewType` follows its subtype. A custom type works in a branch when:

- `cast_from_embedded(dump_to_embedded(value))` gives back a value that is strictly equal (`===`) to `value`, for every value the type can hold, including `nil`, the empty value (`""`, `[]`, `%{}`) and values with surrounding whitespace.
- The embedded form is JSON-safe or one Ramal's codec can tag (atoms, tuples, maps with any keys, dates and times).
- The same input gives the same value whether it goes through the database or the branch, so `cast_input` and `cast_stored` agree on what a row holds, and an untouched row keeps the same fingerprint every time it is read (the staleness check of a merge compares `:erlang.phash2/1` of the loaded attributes).
- A type whose embedded form is not lossless should override `dump_to_embedded/2` and `cast_from_embedded/2` rather than rely on the defaults.

A callback that returns an error makes storing or loading the branch fail, but one that returns a different value changes it silently, which is what these tests are for. The tests in [`test/ramal/custom_types_test.exs`](https://github.com/agustinrojas1/ramal/blob/main/test/ramal/custom_types_test.exs) show the contract on three types in `test/support/customs.ex`: a `NewType` over `:string` with `trim?: false` and `allow_empty?: true`, a JSON type with nested lists of maps, and a struct whose caller, database and embedded forms all differ (as a PostGIS `Geo` struct's do). They check, for ETS, Postgres and durable branches, that create, update, read, `diff/2`, fork, store and reload, and merge all give the value the database gives, and that a row the branch only read is never reported stale. Copy that shape to test your own type. The PostGIS type itself is not tested, because it needs a database with PostGIS and the test database is plain Postgres.
