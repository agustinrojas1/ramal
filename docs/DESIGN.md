# Ramal design

Status: describes Ramal 0.9. First written 2026-10-22. This document is the current state of the design; the history of
decisions lives in `docs/adr/`. Where this document and the code disagree, open an issue: one of them is wrong.

Marks: **[confirm]** flagged an Ash behaviour the implementer had to verify against the locked version before relying
on it. Every one in this document has been resolved for 0.1, into a module doc or an ADR (the decision log below links
them); a new mark means a new unverified assumption and should be resolved the same way. Locked versions: Ash 3.37,
AshPostgres 2.15, Spark 2.7.

## 1. Goal and non-goals

**Goal.** Give an Ash application many cheap, isolated, persistent alternate states of its data ("branches") that
ordinary Ash code can read and write without knowing it is inside one, plus the operations to fork, diff, merge and
discard them. A branch must cost roughly what a process and a map cost, so thousands can be alive at once.

**Non-goals.**

- Schema changes inside a branch.
- Branch-local indexes, or any promise about query plans.
- Data-layer aggregates and calculations that Ramal cannot recompute over a branch (`custom` aggregates, join filters and custom read actions keep the database's value, with a telemetry event; section 4.1 point 4 says what is recomputed).
- Multi-node branches by default. A branch lives on one node; persistence makes it movable. `cluster: true` makes one process serve a branch for every node of a cluster that shares the Postgres storage (section 6, ADR 0044).
- A UI. The inspector is a separate package (`ramal_live/`, section 12).

## 2. Concepts

**Branch.** `%Ramal.Branch{}`: `id` (UUID string), `name`, `domain` (the Ash domain whose resources it covers; a resource of another domain that uses `Ramal.Resource` is branched too, section 11), `status` (`:open | :proposed | :merged | :rejected | :discarded`), `base` (fingerprints and snapshots, section 7), `overlay`,
`log`, `inserted_at`, `metadata` (a map the host uses freely), `owner` (any term the host set at `branch/2` or `fork/2`, `nil` by default; `Ramal.list/2` can filter by it, ADR 0018), `proposal` (`nil` until proposed, section 7.1), `durable` (whether each action that ends is appended to the storage's write log, section 6, ADR 0048) and `wal` (the number of the last delta of that log the struct includes).

**Overlay.** A map from `{resource_module, primary_key}` to one of `{:created, record}`, `{:updated, record}` or
`:deleted`. The record is the full Ash struct as the action left it. The primary key is the value of the resource's
primary key attribute, or a tuple for composite keys. The overlay is the branch's only state that matters for reads.
Entries record the net effect on the base, so a row created and then deleted in the same branch leaves no entry, and
a row deleted and then created again becomes `:updated` (the base row is replaced). `Ramal.Overlay` documents the full
table of how an entry combines with the next write. The overlay is a plain map and does not remember write order; the
log does.

**Log.** A list of entries `{action_type, resource, action_name, input, actor, opts, at}` recording every
write the branch captured, newest first so recording one is O(1); readers reverse it. The log is what `merge/2` replays. The overlay is derived from the log in
principle, but kept materialized because reads need it on every query.

**Fingerprints and snapshots.** `base` maps `{resource, key}` to `%{fingerprint, snapshot}` for every base row the branch
touched. The fingerprint is `:erlang.phash2` of the row's attributes (`Ramal.Resource.fingerprint/1`) at the first read
or write; it is `nil` when the row was read with `select`, since a hash of part of a row cannot be compared with a
hash of the whole. The snapshot is the row as the first write found it, `nil` for rows only read. Section 7 uses
fingerprints to detect that the base moved under the branch; `diff/1` uses snapshots.

**Change.** `%Ramal.Change{resource, key, kind, changes}` where `kind` is `:created | :updated | :deleted` and
`changes` maps attribute names to `{before, after}`. `diff/1` returns a list of them in log order. (The Ash change
module that captures writes, section 4.2, is `Ramal.Capture`; the name `Ramal.Change` belongs to this public struct.)

## 3. Process model

- `Ramal.Supervisor` (a `DynamicSupervisor` plus a `Registry` keyed by branch id). The host adds it to its tree:
  `{Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}`.
- Ramal.Cluster (internal): with `cluster: true` the branch registry is `:global` instead of the `Registry`, and
  this is its `:via` module and the resolver that decides which process keeps a name two nodes both registered
  (section 6, ADR 0044).
- Ramal.Branch.Server is a `GenServer` per open branch. State is the `%Ramal.Branch{}`. It owns the overlay and the
  log; every write inside the branch is a `GenServer.call` to it, every read asks it for the part of one resource's
  overlay that the read can use (ADR 0020). Reads of the overlay are frequent and small; if they become a bottleneck, the server publishes the
  overlay to an ETS table it owns. Not before the benchmark says so.
- Idle branches unload: after `idle_timeout` (default 5 minutes, a `Ramal.Supervisor` option) the server persists its
  state through the storage backend and stops. If the storage refuses the write the process stays loaded, with its
  overlay, and tries again at the next idle timeout (`[:ramal, :branch, :persist_failed]`). A branch is also persisted when it is created, discarded, and when the
  supervisor shuts down; writes in between live only in the process (ADR 0003), unless the branch is durable.
- Durable branches (`durable: true` at `branch/2`, or on `Ramal.Supervisor`, ADR 0048): when the outermost captured action
  of a process ends, `Capture` calls `Server.commit/1` instead of casting `release`. The server builds the delta of that
  action (`Ramal.Branch.delta/2`: the overlay entries and base rows of the rows the action wrote as they stand, the rows
  whose entry is gone, the log entries, the count of placeholder keys), appends it to the storage's write log under the next `seq` and answers; the
  action returns only then, and fails with `:storage` if the append fails. A delta holds the action's own rows and no
  other, so it holds nothing of an action still running (a row is never held by two). The log is compacted by a
  snapshot (`put/2` of the branch without running actions' writes, which deletes the deltas up to its `wal`) after 100
  appends, after a load that applied deltas, on unload and on shutdown. A load is the snapshot with the deltas after
  its `wal` applied in `seq` order, the order the actions ended in. A `seq` is never reused: an append that errors may
  have been stored, so the process gives it up and compacts at once. A nested fork of a durable parent is durable; `adopt/4` stores the parent whole, which is a snapshot covering its log. In a cluster the append and the read of the log are fenced by the epoch like `put/2` (ADR 0044): a refused append fails the action with `:fenced` and stops the process, and a load reads the log after its claim. The fingerprints of rows the branch read and did not write since the last snapshot are not in any delta, so after a crash the merge cannot tell that such a row changed in the database; every row an action wrote keeps its fingerprint (ADR 0048, consequences).
- Running actions: a captured write belongs to its action until the action ends. The server keeps its undo under the
  writer's pid and monitors it; a merge or a proposal waits for running actions, a fork leaves their writes out, another
  process's write to the same row is refused (`:row_busy`), and a writer that dies is undone (ADR 0033). `Ramal.branch/2`, `run/2`, `fork/1`, `diff/1`, `merge/2` and `discard/1` all accept a branch id and
  rehydrate the process on demand. The host never needs to know whether the process is alive.
- Limits: `max_active_branches` and `branch_rate`, `Ramal.Supervisor` options, both off by default. The internal module Ramal.Limits checks
  them in `branch/2` and `fork/2` before anything is created, per domain: the first caps the open and proposed branches
  (read from storage with the optional `count/3` callback, so one query with Postgres), the second caps creations per
  fixed window with an atomic counter in the supervisor's ETS table. A refusal is `{:error, :limit_reached}` plus a
  `[:ramal, :limit, :reached]` event (ADR 0016).
- Memory: the branch process points equal terms at one copy (`Ramal.Overlay.share/3`, `Ramal.Branch.share/1`): a message and an ETS table copy a term in full, so without it each row would cost its snapshot, its record and the bookkeeping fields of both. `max_heap_size` on the server process, a `Ramal.Supervisor` option, default 25 million words. A branch that
  exceeds it is killed and its last persisted state remains; a watcher process notices the untrappable kill, emits
  `[:ramal, :branch, :too_large]` and marks the branch, and the next use returns `{:error, :branch_too_large}` until
  the branch is discarded (ADR 0003). A process also marks itself running and clears the mark in `terminate/2`, so one
  that died unmarked is not loaded again from the storage it was ahead of (ADR 0033).
- "Current branch" is process-local. `Ramal.run(branch, fun)` stores the branch id in the process dictionary
  (Ramal.Current) for the duration of `fun`, restoring the previous state afterwards even when `fun` raises. The
  first hook that runs also copies the id into the query's or changeset's Ash `shared` context, because Ash runs some
  loads in tasks that do not inherit the process dictionary. Tasks started with `Task` (and the ones Ash starts) are in
  the branch of the process that started them, through `$callers` (ADR 0026); a process started any other way is not,
  and `Ramal.run/2` inside it propagates the branch explicitly. Resolved in ADR 0002 and ADR 0026.

## 4. Interception: the Spark extension

Resources opt in with `extensions: [Ramal.Resource]`. The extension adds, through a transformer, one global
preparation to every read action and one global change to every create, update and destroy action. It also adds a
`ramal do ... end` section with `branchable? true` (default) so a resource can opt out (a `ramal_branches` table must
never be branchable, for example). `Ramal.branch/2` refuses a domain with no branchable resource (`:no_branchable_resources`). That check runs when the
branch is created, not as a compile-time domain verifier: a verifier would need the domain to opt into an extension
of its own, which 0.1 does not ask of the host. The transformer is Ramal.Resource.Transformer (`@moduledoc false`);
Spark needs a module for it.

Both hooks are no-ops when no branch is current. A test per hook proves that: the same action, with and without the
extension, produces byte-identical results when no branch is active.

### 4.1 How reads are patched

This is the section that decides correctness. In a read action's preparation, when a branch is current:

1. **Before the data layer:** in a `before_action` hook (it runs after every preparation and before the data-layer
   query is built, `lib/ash/actions/read/read.ex`), remember the query's `limit` and `offset` and remove them from
   the query that goes to the data layer. The base query keeps its filter, so Postgres still uses its indexes and
   returns only candidate rows. For OLTP-sized working sets this is cheap; for a query that would return a large
   result the host should not be in a branch. When the overlay has no entry for the resource, nothing is stripped and
   the database pages as usual.
2. **After the data layer:** take the base results and the overlay entries this read can use, then (the branch process
   hands over only the entries of the rows the base returned and the records that may satisfy the filter, so a read
   costs what it returns, not the size of the overlay; Ramal.Prefilter rules records out with plain comparisons and
   never one the filter accepts, ADR 0020):
   - drop every base row whose key is `:deleted` in the overlay;
   - replace every base row whose key is `:updated` with the overlay record;
   - add every `:created` and `:updated` overlay record that is not already present and that **matches the query's
     filter**, evaluated in Elixir with `Ash.Filter.Runtime.filter_matches/4` (domain, records, filter, opts), once for the whole
     slice. An updated row that no longer matches the filter is dropped;
   - re-apply the sort in Elixir with Ash.Actions.Sort.runtime_sort/3 (it lives in Ash.Actions.Sort, not
     `Ash.Sort`, and sorts a list, not pairs), then the remembered `offset` and `limit`. `Ramal.Overlay.patch/4`
     does the merge as a pure function and supplies the filter predicate's rows; the preparation calls it without
     `:sort`, `:offset` and `:limit` and applies those itself;
   - apply `distinct` itself while the overlay touches the resource: the base query is read without it and the patch
     keeps the first row of each group in the order of `distinct_sort` (or `sort`), as `DISTINCT ON` does. A calculation
     is evaluated in memory on the patched rows with `Ash.Query.apply_to/3` (documented in Ash 3.37; it loads the
     calculation with `reuse_values?: true`, so a row the branch changed is judged by its new values), which needs every
     attribute the calculation reads, so a query that selects only some attributes is widened to all of them (the
     result carries the extra attributes, as a distinct on an attribute already adds that attribute). A distinct on an
     aggregate keeps the data layer's;
   - trim overlay records to the query's `select`, since an overlay record is a whole struct and a base row carries
     only the selected attributes (the primary key is always kept);
   - record a fingerprint (section 7) for every base row the data layer returned, before patching (ADR 0006); a read
     that selects some attributes records none.
3. **Loads and relationships:** Ash loads relationships through further read actions on the related resource, so they
   go through the same preparation. Confirmed in Ash 3.37 and covered by tests: the default and `lazy?: true` paths
   of `Ash.load`, loads inside a read, and `Ash.get/3` (the not-found check runs after the `after_action` hooks, so a
   row created in the branch is found). Ash builds the first level of a load in the calling process, where the
   process dictionary is set, and the levels below it inside the task that runs the first level, where it is not.
   The preparation therefore copies the branch id into the query's `shared` context, which Ash passes to related
   queries (ADR 0002); a test outside the SQL sandbox, where Ash really does run loads in tasks, fails without it.
   One path escapes: `Ash.load` onto a record first reselects the relationship's source attribute from the data
   layer, and that read runs no hooks (`reselect_and_load/6` in Ash 3.37), so a foreign key the branch changed is not
   seen and the load follows the database's. Ash gives the preparation no way in (the reselect is a raw data-layer read
   and `reuse_values?` is read from the options before the preparations run), so `Ramal.load/3` is the supported call
   (ADR 0031): inside a branch it puts the branch's attribute values on each record that has an overlay entry and loads
   with `reuse_values?: true`. A load inside a read (`Ash.Query.load/2`) is patched too; the test in
   `preparation_test.exs` pins the plain call, `Ramal.load/3` and both.
4. **Aggregates and calculations:** an aggregate a read loads (`count`, `exists`, `sum`, `min`, `max`, `avg`, `first`, `list`, declared on the
   resource or added to the query) is computed again after the patch from the related records read through the branch, for
   every row when the branch changed a resource on its path and for the rows the overlay supplied otherwise (ADR 0029).
   `first` and `list` take the field of the first and of every related row in the aggregate's sort, `uniq?` deduplicates a
   `list` and counts distinct values in a `count`, `include_nil?` is honoured, and the field may be a calculation (ADR 0039).
   `custom` aggregates, a join filter, a custom read action, a calculation field on `sum`, `min`, `max` or `avg`, and
   a field that is neither keep the database's value and emit
   `[:ramal, :read, :unpatched_aggregate]`, so a host can detect it in tests. A filter or sort on an aggregate is judged on the branch's
   numbers (ADR 0032): the conjunct is taken out of the data-layer query when the branch changed a resource on the
   aggregate's path, as for a relationship (section 9), and the aggregates the filter or sort names are computed over the
   branch for the overlay's records, for the base rows the check reads and for the rows a sort orders. Expression calculations are evaluated in memory on the rows the branch created or changed.
   `Ramal.aggregate/4` (ADR 0011, ADR 0013) gives one total over a query: the database aggregates the rows the overlay does
   not touch and the branch reads only the ones it does.
5. **Pagination:** Ash adds a page's limit and offset (or its keyset filter) after the `before_action` hooks, counts in
   the database and decides `more?` from the database's rows, so the database cannot page a list the overlay changed.
   When the overlay touches the resource, the last `before_action` hook (added from a `before_transaction` hook, so it
   runs after the hooks of every preparation and of the action) reads the whole patched list with the action's own read
   preparation, cuts the page out of it in Elixir and hands the rows to Ash with `Ash.Query.set_result/2`, one more than
   the page so Ash can set `more?`, and the count with the `full_count` context key (`paginate/3`, `fetch_count/5` and
   `run_query/4` in `lib/ash/actions/read/read.ex`, Ash 3.37). A row created in the branch is on the page its sort
   position puts it, a deleted row shortens nothing, `count` is the patched count, and `after`/`before` cursors walk the
   patched list: a keyset filter is judged by `Ash.Filter.Runtime` on the patched rows, so the cursor of a row the
   branch deleted still finds its place. `Ash.stream!/2` pages the same way. The cost is a read of every row the filter
   matches for each page, as for an unpaged read; when the overlay has no entry for the resource the database pages as
   usual. A paged relationship load is cut the same way, per source record
   ([ADR 0030](adr/0030-pages-cut-from-the-patched-list.md), [ADR 0040](adr/0040-relationship-pages-cut-per-source.md)).
6. **Policies:** the query's filter, including one a policy added, is applied to overlay records. Checks that act on
   results (`authorize_results`) are taken off the query once the overlay touches the resource and run on the patched
   rows in the `after_action` hook ([ADR 0037](adr/0037-result-checks-run-on-the-patched-rows.md)).
7. **Many-to-many:** the join resource is a resource like any other and gets its own overlay entries, keyed by its
   primary key (a tuple when the key is the pair of foreign keys). Covered by tests with a join resource that has such a
   key ([ADR 0014](adr/0014-many-to-many-join-resources.md)). A read of the join resource and a load of its
   `has_many` join relationship see the branch's links, and so does a many_to_many load. AshPostgres loads a
   many_to_many with one SQL query that joins the join table in the database (`lateral_join?/4` in
   `lib/ash/actions/read/relationships.ex`), so when the branch holds entries for the join resource the destination's
   read preparation drops that join, reads the patched join rows instead and tags each destination row with its source
   ([ADR 0017](adr/0017-many-to-many-links-in-a-branch.md)). A relationship loaded with a page, a limit or an offset is one
   lateral join that limits per source record; when the branch changed its destination (or the join resource) the same
   hook reads the rows of all the sources whole and pages each source on its own, so the page, its `more?` and its
   count see the branch ([ADR 0040](adr/0040-relationship-pages-cut-per-source.md)). A relationship with a `through` path of
   several hops (`has_many :herd_moves, Move, through: [:herds, :moves]`) is also one lateral join, over the
   intermediate tables; when the branch changed an intermediate resource or the destination, `lib/ramal/preparation/lateral.ex`
   (a module of its own because the walk is longer than the has_many and many_to_many cases of `many_to_many.ex`, and
   named so as not to shadow Elixir's `Path`) reads each hop through the patched reads and tags the destination rows with
   the sources that reach them ([ADR 0046](adr/0046-through-paths-walked-over-the-branch.md)). A path with a many_to_many
   hop is left to the database, which gets it wrong with or without a branch. Because `manage_relationship` decides from that load, `:remove` finds a link the
   branch created and `:append` does not link a vet twice. `type: :append_and_remove` unrelates with `Ash.bulk_destroy/4`
   (`bulk_delete_unused_unrelate/8` in `lib/ash/actions/managed_relationships.ex`), which a branch runs record by record
   like any bulk action ([ADR 0036](adr/0036-bulk-actions-record-by-record.md)).
8. **Text sort order:** once the overlay touches a resource the whole patched list is sorted in Elixir, where strings
   compare as bytes, but Postgres orders text by the collation of the column (`apple` before `Banana` in `en_US.UTF-8`).
   Ramal.Collation (internal, lib/ramal/collation.ex) closes the gap: for a sort on a text attribute of an AshPostgres resource it reads the
   column's collation from `pg_attribute.attcollation` (cached in `:persistent_term`, not for a tenant schema), asks
   Postgres in one query for the `dense_rank()` of the distinct values under that collation (`lower(v)` for `citext`),
   and the in-memory sort orders by those ranks, so ties fall to the next sort key. The same ranks give `:min` and
   `:max` of a string in `Ramal.aggregate/4` and in declared aggregates. A `C` or `POSIX` column skips the query, since
   bytes are its order, and a resource on another data layer keeps byte order. The query is read-only. Two gaps stay:
   a keyset cursor and a comparison filter (`name > "b"`) on text compare bytes
   ([ADR 0045](adr/0045-text-sorted-by-the-databases-collation.md), which supersedes
   [ADR 0024](adr/0024-text-sort-order.md)).
9. **Filters and sorts through a relationship:** the data layer judges `paddock.name == "L07"` with a join against the
   base's paddocks, so a branch that renamed the paddock would leave its herds matched by the old name. When a filter
   or sort reaches a resource the branch has entries for (any hop of the path, and a many_to_many's join resource),
   a helper in lib/ramal/preparation/related.ex takes the conjuncts that reach it out of the data-layer query (the top-level `and` chain
   is split; an `or` or a `not` is one unit) and the preparation evaluates them in Elixir with `Ash.Filter.Runtime` on
   the base rows the branch did not change, loading the relationships first with `reuse_values?: true` so the patched
   reads and the branch's foreign keys are used. Overlay records are judged by the whole filter. A sort on such a path
   loads the relationship and evaluates the calculation in memory. `Ramal.aggregate/4` leaves the delta for these
   queries. The cost is a broader base read ([ADR 0025](adr/0025-relationship-filters-in-elixir.md)), narrowed for a leaf
   through one changed `belongs_to` or `has_one`: the data-layer query keeps `(leaf and fk not in ^changed) or fk in ^matching`
   (`has_one`: the leaf plus the sources the branch's related rows point at), and the Elixir check stays the final word
   ([ADR 0047](adr/0047-relationship-filter-narrowing.md)).

### 4.2 How writes are captured

`Ramal.Capture` is a global change for create, update and destroy actions. When a branch is current
([ADR 0005](adr/0005-write-capture.md)):

- `around_action` adds a last `before_action` that builds the record and calls `Ash.Changeset.set_result/2`, so the
  data layer is skipped. `around_action` itself cannot return a result early, because the before-action hooks run
  inside its callback.
- All of Ash's own work still happens: argument casting, validations, policies, other `before_action` and
  `after_action` hooks, defaults, timestamps. Ramal only replaces "write this to Postgres" with "put this in the
  overlay", so a branch is a faithful rehearsal of the real action.
- The record is `Ash.Changeset.apply_attributes/2`, which also applies defaults. A primary key the database would
  generate (identity integer keys, database defaults) does not exist in a branch, so a single `generated? true` integer
  or UUID key gets a placeholder (integers from `-2_147_483_648` up, random UUIDs) that the merge renames to the key the
  replayed create gets, in the later entries' input and keys too ([ADR 0042](adr/0042-placeholder-keys-for-generated-primary-keys.md)).
  `Ramal.Merge.Result.keys` maps placeholder to real key. Any other generated key fails the action with
  `:database_generated_key`. A sort or a keyset page on a generated integer key compares a placeholder as larger than
  every real key, in creation order, which is where the merge puts the row (Ramal.Preparation.Placeholders, internal,
  one line on why: the sort and the cursor comparison are done in Elixir on the patched list; UUID keys have no order to
  match).
- Destroys mark the key `:deleted`. Updates of a `:created` row stay `:created` with the new record. The first write to
  an existing row keeps the row as the action found it in `base`, which `diff/1` compares against.
- Every write is appended to the log as `{action_type, resource, action_name, params, actor, opts, at}`; `opts` has
  `key`, `tenant`, `nested?` and `root`, and `forced` when the caller set attributes after building the changeset
  (`change_attribute/3`; the replay sets them again). A write made by a hook of another captured action (or by a
  managed relationship) is `nested?: true`, and merge skips it because replaying the outer action runs the hook again;
  `root` names the outermost action, and the replay gives the creates of its hooks the keys they had, so later entries
  find those rows (ADR 0041). An update that changes
  no attribute is logged too, with the row left as it was and out of `diff/1`, because its hooks and managed
  relationships can write other rows and only the outer action can replay them (ADR 0014).
- A failing action takes back its own writes and those of the actions its hooks ran.
- **The branch is checked again when the action runs** (ADR 0026). A changeset built outside `Ramal.run/2` and run
  inside it, or built inside and run after it, or built under one branch and run under another, fails with
  `:branch_mismatch` instead of writing to the wrong place. A captured write from a task that a hook of another captured
  action started fails with `:task_in_action`. A query prepared outside a branch and read inside it is patched: the
  preparation adds a `before_transaction` hook (Ash refuses an atomic bulk update of a query with a `before_action` or
  `after_action` hook, but not this one) that installs the read hooks when a branch is current (ADR 0028).
- **Every resource of the domain is covered or opted out** (ADR 0027): `Ramal.branch/2` refuses a domain with a
  resource that has write actions and neither uses `Ramal.Resource` nor sets `branchable? false` (`:unbranchable_resources`).
  A resource that opts out is written for real.
- **Notifications** are dropped by default. `Ramal.run/2` runs the function inside `Ash.transaction([], ...,
  return_notifications?: true)` and sends only the notifications of resources with `notify_in_branch? true`. A write
  made with `context: Ramal.context(branch)` cannot be held back that way, so its notifiers fire; `Ramal.in_branch?/1`
  lets a notifier skip it.
- **Atomic updates:** `atomic/3` returns `{:not_atomic, reason}` while a branch is current, and the transformer sets
  `require_atomic? false` on the resource's update and destroy actions so that Ash falls back to the path above.
- **Atomic updates** (`atomic_update`) are evaluated in Elixir against the row with the action's attribute changes
  applied, with `Ash.Expr.eval/2` as `Ash.DataLayer.Ets` does. An expression that needs the database fails the action
  with `:atomic_unsupported`.
- **Bulk actions run record by record** (ADR 0036). Ash runs a changeset that has an `around_action` hook singly,
  through the single action (`split_and_run_simple/7` in `lib/ash/actions/helpers.ex`), so each record of
  `Ash.bulk_create/4`, `bulk_update/4` and `bulk_destroy/4` is captured and logged as its own action and the data layer's
  bulk call gets none. A bulk update or destroy of a query must allow `:stream`, because neither atomic strategy can run
  in a branch. A `before_action` guard refuses, with `:bulk_unsupported`, an action the `around_action` hook did not
  wrap, so a path that skipped it fails instead of writing the base.
- **Upserts** are decided in the branch's view ([ADR 0038](adr/0038-upserts-in-the-branch-view.md)): the capture reads
  `upsert?` in `change/3`, where it is the action's own (Ash's `do_run` sets it for every create before the hooks), looks
  the row up by the upsert identity with a patched read, and logs a found row as an update and a missing one as a create.
  The log entry carries `upsert: {identity, fields, found?}` and the merge replays it with `upsert?: true`.
  `upsert_condition` is refused with `:upsert_unsupported`. The call-time option `upsert?: true` cannot be seen by a hook
  and acts as a create.
- Errors added by the hook are `Ramal.Error` structs (a Splode error), found in an Ash error with
  `Ramal.Error.find/1`.
- Transactions: an action that opens a data-layer transaction inside a branch still opens one (cheap, empty). Nothing
  is written, so nothing needs rolling back. 0.2 may skip it.

## 5. Public API (0.1)

```elixir
@spec branch(domain :: module, keyword) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
# opts: name, metadata, owner, tenant, durable

@spec run(branch | id, (-> result)) :: {:ok, result} | {:error, Ramal.Error.t()}
@spec run!(branch | id, (-> result)) :: result

@spec current() :: Ramal.Branch.t() | nil

@spec context(branch | id) :: map
# the Ash context that puts one read or write in the branch: `Ash.read!(Herd, context: Ramal.context(branch))` (ADR 0019)

@spec fork(branch | id, keyword) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
# the fork is a new branch with a copy of overlay, log and fingerprints; metadata.forked_from = parent id
# `nested: true` makes it a branch of the parent that merges into it (ADR 0043, section 8)

@spec diff(branch | id, keyword) :: {:ok, [Ramal.Change.t()]} | {:error, Ramal.Error.t()}
# `against: :parent` for a nested fork: what merging it would change in its parent

@spec merge(branch | id, keyword) :: {:ok, Ramal.Merge.Result.t()} | {:error, Ramal.Error.t()}
# opts: actor, authorize? (default true), on_stale (:error | :ignore | (stale_rows -> :continue | :abort)), mode (:replay)

@spec propose(branch | id, keyword) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
# opts: proposed_by, reason

@spec approve(branch | id, keyword) :: {:ok, Ramal.Merge.Result.t()} | {:error, Ramal.Error.t()}
# opts: decided_by, reason, and the options of merge/2

@spec reject(branch | id, keyword) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
# opts: decided_by, reason

@spec aggregate(query | resource, kind, field | nil, keyword) :: {:ok, term} | {:error, Ash.Error.t()}
# kind: :count | :exists | :sum | :min | :max | :avg | :first | :list, computed in Elixir over the rows a read returns in the branch

@spec load(record | [record], load, keyword) :: {:ok, record | [record]} | {:error, Ash.Error.t()}
# Ash.load/3 that follows the branch's foreign keys (ADR 0031)

@spec discard(branch | id) :: :ok | {:error, Ramal.Error.t()}

@spec get(id) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
@spec list(domain, keyword) :: {:ok, [Ramal.Branch.t()]} | {:error, Ramal.Error.t()}
# status filter; from storage, not from the registry
```

`Ramal.Error` has `reason` (an atom from a documented list), `message`, and `details` (a map). The reasons:
`:not_found`, `:not_open`, `:stale`, `:database_generated_key`, `:bulk_unsupported`, `:upsert_unsupported`, `:atomic_unsupported`, `:branch_too_large`,
`:no_branchable_resources`, `:nested_branch`, `:missing_snapshot`, `:not_started`, `:storage`, `:timeout`, `:merge_failed`,
`:multitenancy_unsupported`, `:tenant_mismatch`, `:partial_record`, `:branch_mismatch`, `:task_in_action`,
`:unbranchable_resources`, `:row_busy`, `:limit_reached`, `:ash_incompatible`. `lib/ramal/error.ex` holds the authoritative table.

`Ramal.Ash` (public) is Ramal's contract with Ash: the Ash and AshPostgres versions the suite passes on, and the Ash internals Ramal relies on, so that a change in Ash has one place to look. `Ramal.Supervisor` compares the host's versions with it at boot and warns when they are outside the range. It never refuses to start.

Ramal also checks that contract where it runs (ADR 0049). Ramal.Ash.Contract (internal) lists each assumption with its tier, the feature it serves, its tripwire test and a check; Ramal.Ash.Probe (internal, with its Ramal.Ash.Probe.* submodules) holds the small ETS resources and hooks the checks run on, which do not use `Ramal.Resource`. `mix ramal.doctor` (public) runs the checks on the host's Ash and prints each one. The supervisor runs them at boot outside the tested range. A broken core assumption makes every branch read and write fail with `:ash_incompatible`; a broken extended one makes only its feature fail.

### 5.1 Agent tools (ADR 0019)

`Ramal.Tools` gives an LLM agent the branch calls as tools, with no dependency on an AI library:

```elixir
@spec definitions(keyword) :: [%{name: String.t(), description: String.t(), input_schema: map}]
@spec call(String.t(), map, keyword) :: {:ok, map} | {:error, String.t()}
# opts: domain (required), owner, proposed_by
```

The tools are `ramal_open_branch`, `ramal_list_branches`, `ramal_fork_branch`, `ramal_branch_diff`, `ramal_propose_branch`
and `ramal_discard_branch`. `merge/2`, `approve/2` and `reject/2` are left out on purpose: an agent proposes, a person
decides. The options belong to the host: a branch of another domain or owner is reported as not found, whatever id the
model passes. The agent's own reads and writes are the host's tools, run in the branch with `run/2` or with
`context: Ramal.context(id)`. The guide is `docs/agents.md`.

## 6. Persistence

`Ramal.Storage` is a behaviour: `put(branch, config)`, `fetch(id, config)`, `delete(id, config)`,
`list(domain, filters, config)` (which returns `{:ok, branches}` or `{:error, error}`) and the optional
`count(domain, statuses, config)` (how many branches have one of the statuses; without it the limits count with `list`) and
`mark_merged(branch, config)` (stores the branch as merged unless it already is, called inside the merge's transaction,
ADR 0035) and `append(branch, seq, delta, config)` with `writes_after(branch, config)` (the write log of durable branches,
ADR 0048: append one delta, and the deltas after `branch.wal`, oldest first; `put/2` of a durable branch deletes the deltas
its `wal` covers; a durable branch is refused on a storage without the pair), where `config` is the `Ramal.Supervisor` options that are not its own (the Postgres
backend reads `:repo` from it). Two implementations:

- `Ramal.Storage.ETS`: a named table owned by `Ramal.Supervisor`, and an ordered one for the write log (the first is scanned whole by `list/3`). Default in tests and development. Lost on restart.
- `Ramal.Storage.Postgres`: one table `ramal_branches` (`id uuid pk, domain text, name text, status text, state jsonb,
  inserted_at, updated_at`, and `owner jsonb`, which Postgres generates from `state -> 'owner'` and a hash index serves,
  ADR 0021), and `ramal_branch_writes` (`branch_id uuid`, `seq bigint`, `delta jsonb`, key `(branch_id, seq)`, cascading
  from `ramal_branches`) for the write log. `mix ramal.gen.migration` writes the migrations that are missing into the host's repo. Requires AshPostgres
  (or at least Ecto SQL); the module compiles only when it is present.

A cluster (`Ramal.Supervisor` `cluster: true`, ADR 0044) names branch processes with `:global` (Ramal.Cluster, the `:via`
module and the resolver that keeps the process with the higher epoch) and needs the optional `claim(id, config)`: it
increments the branch's `epoch` and returns the stored branch carrying it. `put` and `mark_merged` of a branch that has an
epoch are conditional on it and return `:fenced` otherwise; the process then emits `[:ramal, :branch, :fenced]` and stops. What that process held since its last save is lost and announced, unless the branch is durable: a durable branch appends each action before the action returns, so only an action the losing process cannot store fails (`:fenced`), and no acknowledged write is lost.
The epoch is the `Ramal.Branch` field `epoch` (`nil` without a cluster), the `epoch` column of `ramal_branches`, and is
never part of `state`. `verification/tla/Cluster.tla` models it.

`:global` has a long record of trouble under partial network partitions, where nodes see different subsets of the
cluster. OTP 25 turned on `prevent_overlapping_partitions` by default, which disconnects nodes to restore a fully
connected view. By default a name clash after a split is settled by killing one of the two processes; Ramal's resolver
asks the loser to stop through its own persist path instead, and the storage refuses any save that would overwrite the
winner (Ramal.Cluster). Registration takes a cluster-wide lock, so it costs
more as the cluster grows. Ramal accepts this because it does not rely on `:global` for safety: `:global` only decides
which process serves a branch, and the storage's epoch decides which process may write. A process that `:global` gets
wrong is refused at its next save (ADR 0044, `verification/tla/Cluster.tla`).

Serialization is `Ramal.Storage.Codec`, a pure module any text-based backend can use. The branch columns hold `id`,
`domain`, `name` and `status`; `state` holds the overlay (`resource`, `key`, `op`, `record`), the base (`resource`,
`key`, `fingerprint`, `snapshot`), the log, the metadata and `inserted_at`. A record is `attrs` (each attribute dumped
with `Ash.Type.dump_to_embedded/3` and loaded with `Ash.Type.cast_from_embedded/3`, both confirmed in Ash 3.37), the
names of unloaded attributes, and the other struct fields when they differ from a fresh struct. The state is compact (version 2, [ADR 0022](adr/0022-compact-state.md)): common date structs are ISO 8601 text, a struct lists only fields that differ from its default, shared record parts are written once, and a snapshot is stored as its difference from the record. Action input,
primary keys, options and actors are stored as tagged terms; actors are stored as the term itself, not through a
serializer (pass `actor:` to `merge/2` to replace a stored one). Atoms are never created from stored data. See
[ADR 0008](adr/0008-postgres-storage.md).

## 7. Staleness and merge

Every base row a branch reads or writes gets a fingerprint: `:erlang.phash2` of its attribute map at first touch,
keyed by `{resource, key}`. On `merge/2`:

1. Refuse inside `Ramal.run/2` (`:nested_branch`) and claim the branch: it must be `:open` and not already merging.
   While claimed, the branch process refuses every other call, so nothing is written between check and replay.
2. Inside one `Ash.transact/3`, re-read every fingerprinted row from the base (one query per resource, key filter,
   `FOR UPDATE` where the data layer supports it, and whatever the primary read action's pagination: the read skips it
   with Ash's `unpaginated_read` in `lib/ash/actions/read/read.ex`, because a page would cut the set at the
   default limit). A row whose hash differs is `:changed`; one that no longer exists
   is `:deleted`.
3. Apply `on_stale`: `:error` (default) returns `{:error, %Ramal.Error{reason: :stale, details: %{rows: [...]}}}`;
   `:ignore` continues; a function receives the stale rows and returns `:continue` or `:abort`.
4. In the same transaction, replay the log oldest first through the real actions with the real data layer (no branch
   current), skipping entries logged by hooks of other captured actions (`nested?: true`). The actor is the `actor`
   option if given, else the one recorded with each entry. A replayed create keeps the primary key it had in the
   branch. Any failure rolls the transaction back and returns `:merge_failed` with the log entry's `index`. Validations
   run again, so a branch that was valid against a base that has since moved can legitimately fail here; that is the
   feature. An update or destroy of a row the staleness check just read (and locked) takes that row from there
   instead of reading it again, once per row; the reuse stops for good at the first entry a hook wrote.
5. Still in the transaction, store the branch as `:merged` through the storage's `mark_merged/2`, which refuses a
   branch it already holds as merged, so a merge that committed is never run again even when the process that ran it
   died before it finished (ADR 0035). Then stop the process. Return a `Ramal.Merge.Result` with the records the replay
   produced, keyed like the overlay. On failure the claim is released and the branch stays open.

Limits and the reasons for these choices are in [ADR 0007](adr/0007-merge.md).

### 7.1 Proposals (0.2)

A branch can be frozen as a proposal that someone decides on, with the decision recorded on the branch itself.

- `propose(branch, proposed_by:, reason:)` moves an `:open` branch to `:proposed` and stores `proposal: %{proposer, reason,
  proposed_at, decision: nil}`. The branch is persisted before the call returns. A proposed branch refuses `run/2`, `fork/2`,
  `merge/2` and a second proposal (`:not_open`); `diff/1`, `get/1` and `list(domain, status: :proposed)` work, which is
  what a reviewer needs. The proposer can still `discard/1` it.
- `approve(branch, decided_by:, reason:, ...merge options)` is `merge/2` on a `:proposed` branch, plus the decision:
  `%{status: :approved, by, reason, at, replayed, stale}`, written in the same step that marks the branch `:merged`. A stale
  base or a failing replay returns the errors of `merge/2` and leaves the branch `:proposed`.
- `reject(branch, decided_by:, reason:)` records `%{status: :rejected, ...}`, sets the status to `:rejected`, persists, and stops
  the process. Overlay and log are kept, so the rejected diff stays readable.
- Ramal does not decide who may approve. The host authorizes before calling; `:decided_by` is recorded, not checked.
- No new table: the proposal is a field of the stored branch state, and the status column gains two values. The diff at
  decision time is `diff/1` of the stored branch, which is frozen from the proposal on ([ADR 0012](adr/0012-proposals.md)).

`mode: :replay` is the only merge mode in 0.1. A future `:apply` mode would write the overlay's final state directly,
skipping action logic; it is faster and less safe, and needs its own ADR.

## 8. Fork and diff

- `fork/2` copies overlay, log and `base` into a new open branch with its own process, a fresh id, the parent's name,
  metadata and owner unless given, and `metadata.forked_from`. Both branches share the database; neither sees the other's later
  changes. Persistent data structures make the copy cheap; the log is a list and gets shared structurally. A fork of a
  branch that is not open is `:not_open`. It emits `[:ramal, :branch, :fork]` with `parent_id` and `nested`, then `:load`.
- `fork/2` with `nested: true` makes a branch of the branch (ADR 0043). It records `parent: %{id, log_length}`, the length
  of the log it inherited, and `parent_seen`: for each row it reads or writes, what it held the first time (`:base`
  without an overlay entry, otherwise the hash of the entry), which is what the parent held when it was forked. Merging
  it (`merge/2`, `approve/2`) claims it, copies the parent with its `version` (waiting for the actions running in it),
  compares `parent_seen` with the copy (`:stale`, `on_stale` applies), replays the entries the fork wrote itself through
  the real actions in a scratch branch that is never stored, and gives the parent the scratch's overlay, log and
  `base` in one call that checks the `version`, persists the parent and records the fork's id in `merged_children`. A
  parent that changed meanwhile makes the merge run once more, and then fail as `:stale`; a failed replay leaves the
  parent as it was. The parent keeps the earliest fingerprint of every base row, so its own merge to the database
  checks the rows the fork read. A fork its parent holds is merged, whatever its own status says: the branch process
  asks the parent's storage when its merger dies and when it is loaded. A parent that is not open refuses
  (`:parent_not_open`). `Ramal.run/2` inside `Ramal.run/2` stays refused. `diff(fork, against: :parent)` compares the
  fork's own writes with the parent's copy of the rows.
- `diff/1` walks the overlay: for `:updated`, compare the overlay record with the base row as the branch first saw it
  (kept alongside the fingerprint, so diff never queries the base) and keep only the attributes that differ; for
  `:created`, every attribute is `{nil, value}`; for `:deleted`, `{value, nil}`. An updated row whose values ended equal
  to the base is left out. Output order is the log order of first touch: `Ramal.Overlay.diff/3` computes the changes
  (sorted by ref, because the overlay map has no order) and `diff/1` reorders them by the log (`Ramal.Branch.diff/2`, with the Ash-aware `Ramal.Resource.attributes/1`). An updated or deleted
  entry with no base snapshot is `{:error, %Ramal.Error{reason: :missing_snapshot}}`: the write layer forgot to keep one.

## 9. Telemetry

Events, all with `%{branch_id, domain}` metadata:

`[:ramal, :branch, :create]`, `[:ramal, :branch, :fork]`, `[:ramal, :branch, :unload]`, `[:ramal, :branch, :load]`,
`[:ramal, :branch, :persist_failed]` (storage refused a write on `:idle`, `:shutdown`, `:merged`, `:append` or `:compact`, with the `error`),
`[:ramal, :branch, :append]` (a durable branch stored an action's delta: `seq`, `rows`, measurement `duration`), `[:ramal, :branch, :compact]` (a snapshot covering the write log: `wal`, `duration`),
`[:ramal, :branch, :discard]`, `[:ramal, :branch, :propose]`, `[:ramal, :branch, :approve]`, `[:ramal, :branch, :reject]`, `[:ramal, :branch, :too_large]`, `[:ramal, :merge, :start | :stop | :exception]` (span; `stop` adds `result: :ok | :error` and `replayed` or `reason`),
`[:ramal, :read, :patch]` with measurements `%{base_rows, overlay_rows, result_rows, duration}`,
`[:ramal, :read, :unpatched_aggregate]`, `[:ramal, :write, :capture]` with `%{action_type, resource, action, nested?}`.

`[:ramal, :branch, :load]` is emitted every time a branch process starts, including right after creation, so
`create` is followed by `load`. `unload` carries `reason: :idle | :shutdown`. `discard` is emitted once per discard
and is not followed by `unload`.

## 10. Test domain

`test/support/farm/`: domain `Ramal.Test.Farm` with five resources on `Ramal.TestRepo` (AshPostgres), all with
timestamps and, except the join resource, UUID primary keys:

- `Paddock`: `name`, `hectares`, `capacity_head` (integer).
- `Herd`: `name`, `head` (integer), `belongs_to :paddock`.
- `Move`: `belongs_to :herd`, `from_paddock_id`, `to_paddock_id`, `moved_on` (date).
- `Vet` and the join resource `HerdVet` (`assigned_on`, primary key `{herd_id, vet_id}`): `Herd` and `Vet` are
  `many_to_many` through it. `Herd` has three update actions, `add_vets`, `drop_vets` and `set_vets`, that manage the
  relationship with `type: :append`, `:remove` and `:append_and_remove`.

Actions: `Herd.move(to_paddock_id)` with a validation "destination capacity not exceeded" that reads the
destination's herds (so a branch must see its own earlier moves for the validation to be right), creating a `Move`
in an `after_action`. `Paddock` declares aggregates over its herds (`head_count`, `herd_count`, `has_herds`, ...), and `first_herd_name`, a kind
the preparation cannot compute, to document the unpatched-aggregate event with a test. One policy on `Herd` (only `%{role: :admin}` may move) to prove policies run inside a branch.

`test/support/texts.ex` is a second domain, `Ramal.Test.Texts`, with `Tag`: one text column for each way Postgres orders text (the database default, `C`, ICU's `und-x-icu` and `citext`), an atom column and a self-reference, for the collation tests ([ADR 0045](adr/0045-text-sorted-by-the-databases-collation.md)).

The domain mirrors the first real user of Ramal (an agricultural operations app) and stays in English.

## 11. Open questions

1. ~~Several domains per branch?~~ A branch names one domain, which is the one `Ramal.branch/2` checks for resources that neither use `Ramal.Resource` nor opt out. The overlay is keyed by resource, so a resource of another domain that uses `Ramal.Resource` is read, written, diffed and merged like the rest (`test/ramal/other_domain_test.exs`); one that does not is written for real, and Ramal does not check its domain.
2. Should `run/2` be reentrant (a branch inside a branch)? No, `{:error, %Ramal.Error{reason: :nested_branch}}`; `merge/2` refuses the same way. A branch of a branch is a nested fork, which is run on its own (ADR 0043, section 8).
3. ~~Where do many-to-many join resources sit in the overlay?~~ Answered: they are resources, so they get overlay
   entries like any other, keyed by the join resource's primary key (section 4.1 point 7, ADR 0014). A many_to_many
   load and `manage_relationship` see links the branch changed (ADR 0017); a `through` path of several hops sees them too (ADR 0046), and `append_and_remove` with a link to remove works, as a bulk action run record by record (ADR 0036).
4. ~~Does the read preparation need to handle `Ash.Query.select`?~~ Answered: Ash always selects the primary key, and
   the preparation trims overlay records to the select (section 4.1).
5. Should fingerprints cover rows read through relationship loads? 0.1: yes, because they are reads like any other
   (ADR 0006). Measured by `bench/` (20,000 rows, one 4-core machine): hashing costs about 1.1 microseconds per row, and
   a read of 2,000 rows inside an empty branch takes about 67% longer than the same Ash read outside one, the hash and
   the call that stores the fingerprints together. Kept for now; the numbers and their limits are in `bench/README.md`.
6. ~~Multitenancy~~ Decided for 0.1: refused inside a branch (ADR 0009). Now a branch works in one tenant,
   `Ramal.branch(domain, tenant: tenant)`, so the overlay key and the base ref need no tenant (ADR 0034).
7. ~~Should `Ramal.Storage.Postgres` take a host callback for actors?~~ No: actors are stored as the term, with the
   attributes marked `sensitive?` dropped from resource records (ADR 0008, ADR 0010).

## 12. Inspector (`ramal_live`, 0.4)

A separate Mix project, `ramal_live/`, that depends on `ramal` by path. Core never depends on it. Public modules:

- `RamalLive.Router`: the macro `ramal_inspector path, domain: ..., pubsub: ..., actor: ...` (options `:actor`, required, and `:debounce`). It
  expands to one `live` route, so the host puts it inside its own scope, pipeline and `live_session` and the page uses the
  host's root layout, LiveView socket and JavaScript (ADR 0015).
- `RamalLive.Broadcaster`: a process the host starts. It attaches telemetry handlers (the branch lifecycle events,
  `[:ramal, :write, :capture]`, `[:ramal, :merge, :stop]`) and broadcasts `{:ramal_live, branch_id, event}` on the host's
  PubSub, topic `"ramal_live:" <> domain`. No row data travels in the message.
- `RamalLive`: the setup guide.

Internal (`@moduledoc false`): `RamalLive.InspectorLive` (the page), `RamalLive.BranchColumn` (a LiveComponent per branch),
`RamalLive.Column` (the pure view model: facts and before/after rows as strings), `RamalLive.Events` (event names, topic,
the telemetry handler) and `RamalLive.Style` (the inline CSS).

**The page.** Open branches, then proposals, each oldest first, as columns. A column shows the name, status, short id, age,
overlay size (rows and writes), `forked_from`, the proposal's proposer and reason, and `Ramal.diff/1` as before and after
rows (the first 100 changes; the rest are counted). Buttons: fork, merge and discard on an open branch; approve and reject
on a proposal. Merge, discard, approve and reject show an inline "are you sure?" first, and the server accepts the second
event only after the first. Merge and approve run in `start_async`.

**What it reads.** `Ramal.list/2` (with `owner:` when the route has an `:owner` function, ADR 0018) for the ids, then `Ramal.get/1` and `Ramal.diff/1` per branch, so the page shows what
the public API shows, and loads the processes of the branches on screen. A telemetry event re-reads only the branch it
names, after a `:debounce` window (default 50 ms) that coalesces a burst of writes. Each read emits
`[:ramal_live, :column, :read]` with `%{branch_id, domain}` and a `duration`.

**Identity.** Slate `#243044` for the base line, copper `#D98324` only for branches; the dark theme uses the dark logo's
cream and light amber. Barlow Condensed for headings and IBM Plex Mono for data, with system fallbacks, because the page
does not load fonts. No Tailwind and no asset pipeline: the CSS is inline, scoped to `.ramal`, and follows
`prefers-color-scheme` unless the buttons in the header pick a theme.

**Authorization** is the host's: put the route behind its pipeline or `on_mount`. The `:actor` option is required and supplies
the actor recorded as `decided_by` and used to replay a merge; a function that returns `nil` makes the page refuse every
action (ADR 0016).

## 13. Decision log (summary; details in `docs/adr/`)

| # | Decision | Why |
|---|---|---|
| 1 | Hooks (preparation + change) instead of a wrapping data layer | A wrapping data layer breaks every tool that checks `data_layer(resource) == AshPostgres.DataLayer` (migrations, codegen) and must mirror AshPostgres' DSL. Hooks leave the resource's data layer untouched. |
| 2 | One process per branch | Isolation, lifecycle and limits come from the runtime for free. |
| 3 | Overlay materialized, log authoritative for merge | Reads need the overlay on every query; merge needs the intent, not the state. |
| 4 | Merge replays actions rather than writing state | Validations and policies run against the real base at merge time. Slower and right. |
| 5 | Limit and offset applied after patching | The only way a branch-created row can appear in a limited query. Documented as the cost of correctness. |
| 6 | No Phoenix in core; AshPostgres optional | Keeps the dependency surface small for the first users. |
| 7 | `Ramal.Change` is the diff struct, `Ramal.Capture` the write hook; the overlay records net effect | One name for one thing, and `diff` can rely on `:deleted` meaning the base had the row. [ADR 0001](adr/0001-change-struct-and-capture-module.md) |
| 8 | The current branch id lives in the process dictionary and in Ash's shared context | Ash has no ambient context, and it runs some loads in tasks that lose the process dictionary. [ADR 0002](adr/0002-current-branch-carrier.md) |
| 9 | Idle timeout and heap limit belong to the supervisor; discard keeps the record; storage takes config last | A per-branch value is lost on unload, and a kept record gives `:not_open` a meaning. [ADR 0003](adr/0003-branch-process-lifecycle.md) |
| 10 | Reads are patched in `before_action`/`after_action` hooks; nothing is stripped when the overlay has no entry for the resource; the preparation sorts and pages the list itself | The hooks are where Ash allows changing the data-layer query and seeing its rows; `runtime_sort` takes a list, not a comparator. [ADR 0004](adr/0004-read-patching-hooks.md) |
| 11 | Writes are captured by a last `before_action` that sets the result; atomic updates fall back through `atomic/3` and `require_atomic? false`; an upsert is decided in the branch view (ADR 0038); bulk actions run record by record (decision 34); notifications are dropped unless the resource opts in; a failed action undoes its writes; `Ramal.Error` is a Splode error | `around_action` cannot skip the data layer by itself, the atomic path never reaches a hook, and Ash flattens other exceptions to strings. [ADR 0005](adr/0005-write-capture.md) |
| 12 | `base` holds `%{fingerprint, snapshot}` per touched row; every read fingerprints the base rows it returns, except when it selects some attributes; a fork copies everything and records `forked_from` | Staleness needs the state at first read, diff needs the state at first write, and a partial row has no comparable hash. [ADR 0006](adr/0006-fingerprints-and-fork.md) |
| 13 | Merge claims the branch first, checks staleness inside the replay transaction with row locks where possible, and forces created rows to keep their branch primary keys; entries logged by hooks are not replayed | Writes between check and replay would be lost, a check outside the transaction races, and later log entries name rows by key. [ADR 0007](adr/0007-merge.md) |
| 14 | Branches are stored through `Ramal.Storage.Codec`: attributes through the Ash embedded dump and cast, everything else as tagged terms, atoms never created, actors stored as the term; `list/3` can fail | A round trip must be `==`, the Ash `cast_stored` is the data layer's form, not JSON's, and a database can fail. [ADR 0008](adr/0008-postgres-storage.md) |
| 15 | A branch works in one tenant, given at `Ramal.branch/2`; a multitenant resource used with another tenant is refused (`:tenant_mismatch`), and with a tenant in a branch that has none (`:multitenancy_unsupported`) | The overlay is keyed by `{resource, key}`, which is unambiguous for one tenant; the merge staleness read uses the branch's tenant. [ADR 0034](adr/0034-one-tenant-per-branch.md), which replaced [ADR 0009](adr/0009-multitenancy-refused.md) for branches that have a tenant |
| 16 | A stored actor that is an Ash record loses its `sensitive?` attributes; other actors are stored as they are | The branch table should not hold password hashes or tokens, and Ash already has the flag. A serializer callback has one use. [ADR 0010](adr/0010-stored-actors.md) |
| 17 | ~~`Ramal.aggregate/4` reads the patched rows and computes the aggregate in Elixir; `Ramal.Aggregate` holds the pure part~~ Superseded by 19 for the common kinds; the read-every-row path stays for `limit`, `offset` and `distinct` | The data layer's aggregates cannot see the overlay, and Ash offers no hook to make them. Exact for the branch, as expensive as reading the matching rows. [ADR 0011](adr/0011-branch-aggregates.md) |
| 18 | A proposal is a branch status (`:proposed`, `:rejected`) and a `proposal` field of the stored state; approving is merging | A second table and storage API for one record per branch would duplicate what the branch row already persists, and the decision must land in the same step as the merge. [ADR 0012](adr/0012-proposals.md) |
| 19 | `Ramal.aggregate/4` aggregates in the database the rows outside the overlay, reads the overlaid ones through the patched path and joins the two; limit, offset and distinct keep the read-every-row path; the database's part is not fingerprinted | Reading every row made scoring a state cost a table scan (measured in `bench/`). The delta is exact and its cost follows the overlay. [ADR 0013](adr/0013-aggregate-delta.md) |
| 20 | A many_to_many join resource gets overlay entries like any resource; an update that changes no attribute is logged; a many_to_many load reads the patched join rows when the branch changed them; `append_and_remove` with a link to remove works since bulk actions run record by record (ADR 0036) | Hooks and managed relationships write nested rows that only the outer action can replay; AshPostgres loads the relationship in SQL over the base join table, so the preparation replaces that join; the bulk unrelate is a bulk action, which a branch runs record by record through the capture hook. [ADR 0014](adr/0014-many-to-many-join-resources.md), [ADR 0017](adr/0017-many-to-many-links-in-a-branch.md) |
| 21 | The inspector is a separate project whose router macro expands to one `live` route in the host's own `live_session`; options travel as route metadata; a supervised broadcaster turns telemetry into PubSub messages naming a branch, and the page re-reads only that branch | A `live_session` of its own would need its own root layout, socket and JavaScript, which is an asset pipeline; telemetry is node-local, so a handler attached on first page view would miss events. [ADR 0015](adr/0015-inspector-mounting.md) |
| 22 | `ramal_inspector` requires `:actor`; `Ramal.branch/2` and `Ramal.fork/2` can be limited per domain by `:max_active_branches` and `:branch_rate` of `Ramal.Supervisor`, both off by default | A page that acts for nobody lets anyone who reaches the route merge as no one, and an unlimited fork is a process and a row per call. The limits stay off so no host changes behaviour by upgrading. [ADR 0016](adr/0016-security-defaults.md) |
| 23 | A branch has an optional `owner`, stored in the state JSON; `Ramal.list/2` takes `owner:` and `ramal_inspector` an `:owner` function, both off by default; an owner filters, it does not authorize | A host serving several users otherwise keeps its own id-to-user table to show each person their branches. A column would need a migration for hosts that do not scope. [ADR 0018](adr/0018-branch-owner.md) |
| 24 | `Ramal.context/1` makes the shared context public; `Ramal.Tools` offers six branch tools as data and one `call/3`, without merge, approve or reject, scoped by host options; no dependency on `ash_ai` | Tool servers call Ash with `context:` and cannot use `run/2`; an agent proposes and a person decides; the roadmap rules out a dependency on an agent framework. [ADR 0019](adr/0019-agent-tools.md) |
| 25 | A read asks the branch process for the overlay entries it can use, not the whole slice; Ramal.Prefilter rules out overlay records with plain comparisons before the runtime filter, and `Ramal.run/2` asks for the status alone | Copying the overlay to the caller and filtering every overlay record with `Ash.Filter.Runtime` made the cost of a read, and of a get-and-update, grow with the overlay (measured in `bench/`). [ADR 0020](adr/0020-read-selects-overlay.md) |
| 26 | The owner of a stored branch is a column Postgres generates from `state -> 'owner'`, with a partial hash index; `mix ramal.gen.migration` writes the migration that is missing, so 0.3.0 tables upgrade in place | A hot `owner:` filter scanned and parsed every `state` of the domain. A generated column needs no backfill, cannot disagree with `state`, and an old node writing the table during a deploy keeps it correct. A hash index because the owner is any term and a btree entry has a size limit. [ADR 0021](adr/0021-owner-column.md) |
| 27 | A filter or sort through a relationship whose resource the branch changed is taken out of the data-layer query and evaluated in Elixir; `Ramal.aggregate/4` leaves the delta for it | The data layer joined the base's rows, so a renamed paddock left its herds matched by the old name. The cost is a broader base read, which a to-one path of one hop narrows with a rewritten conjunct. [ADR 0025](adr/0025-relationship-filters-in-elixir.md), [ADR 0047](adr/0047-relationship-filter-narrowing.md) |
| 28 | Hooks check the branch again when the action runs; tasks started with `Task` inherit the branch through `$callers` | The branch was decided once, at build time, and lived in one process, so a changeset built elsewhere, a bulk task and a host task wrote for real. Ash 3.37 has no ambient context to set. [ADR 0023](adr/0026-branch-checked-at-execution.md) |
| 29 | `Ramal.branch/2` refuses a domain with a resource that has write actions and neither uses `Ramal.Resource` nor opts out | A write to such a resource reached the database from inside a branch with no signal. [ADR 0024](adr/0027-domain-coverage.md) |
| 30 | An aggregate a read loads is recomputed after the patch from the related records read through the branch; kinds and shapes it cannot do keep the database's value and emit the unpatched event | The database's aggregate never saw the overlay, and a row the branch changed came back with `Ash.NotLoaded`. The cost is a read of the related rows per recomputed row. [ADR 0029](adr/0029-declared-aggregates-in-branches.md) |
| 31 | A paginated read of a resource the overlay touches reads the whole patched list, cuts the page in Elixir and gives Ash the rows with `set_result` and the count with `full_count` | The database cannot page rows it does not have, and Ash fixes `more?` and `count` from the database before any hook after the data layer can speak. The cost is a read of every matching row per page. [ADR 0030](adr/0030-pages-cut-from-the-patched-list.md) |
| 32 | A captured write is held under its action's process until the action ends: merges and proposals wait, forks leave it out, other writers of the row get `:row_busy`, a dead writer is undone; a process that died without `terminate/2` is not reloaded from storage | The TLA+ model (`verification/tla`) found merges, forks and proposals taking writes of actions that then failed, overlay and log diverging, and a killed process reloaded behind its own writes. [ADR 0033](adr/0033-running-actions-hold-their-writes.md) |
| 33 | The merge's transaction stores the branch as merged and refuses a branch stored so; a branch process whose merger died asks the storage before releasing the claim; Postgres never stores a merged row back as open | A merge whose process died after the commit, or whose node restarted before the persist, left the branch open and mergeable a second time (TLA+ model, #143). [ADR 0035](adr/0035-merged-status-in-the-merge-transaction.md) |
| 34 | Inside a branch a bulk action runs each record through the captured single action; a bulk update or destroy of a query must allow `:stream`; a guard refuses an action the capture hook did not wrap | Ash runs changesets with an `around_action` hook singly, and the refusal also blocked `append_and_remove` and AshAi's update and destroy tools. [ADR 0036](adr/0036-bulk-actions-record-by-record.md) |
| 35 | `first`, `list`, `uniq?` and `include_nil?` aggregates, and a calculation as the field of a `first`, `list` or `count`, are computed over the branch like the other kinds | The related rows already arrive filtered and sorted by the aggregate's own query, so the kinds are a reduction over them; only `custom`, which is SQL, cannot be. [ADR 0044](adr/0039-first-list-and-uniq-aggregates.md) |
| 36 | A text sort, `:min` and `:max` inside a branch order by the rank Postgres gives the value under the column's collation, from one read-only query per sort key; `C`, `POSIX` and other data layers keep byte order | Strings compared as bytes in the branch and by `en_US.UTF-8` in the database, so the same read disagreed before and after the merge. No Elixir comparator reproduces a collation; asking the database does. [ADR 0045](adr/0045-text-sorted-by-the-databases-collation.md), supersedes [ADR 0024](adr/0024-text-sort-order.md) |
| 37 | A nested fork (`fork/2` with `nested: true`) merges into its parent by replaying its own entries in a scratch copy that the parent adopts if its version did not change; the parent persists first and remembers the fork; a fork the parent holds is merged however its own status was left | A fork that replayed its whole log into the database could not be merged without its parent. Replaying in a copy keeps the parent untouched when a replay fails, the version makes an adoption valid, and the model checked in `verification/tla/Nested.tla` found the fork that was still writable after its merger died. [ADR 0043](adr/0043-nested-branches-merge-into-their-parent.md) |
| 38 | With `cluster: true` branch processes are named with `:global`, every load takes the next epoch from the storage and every save is conditional on it; a refused process emits `:fenced` and stops; `:global` keeps the higher epoch when split nodes meet | Two nodes sharing Postgres could each hold a branch and the later save overwrote the earlier one's writes. The database, not the network, decides who may write. Marks and telemetry stay per node. [ADR 0044](adr/0044-branches-in-a-cluster.md) |
| 39 | A branch can be durable: the outermost action's end is a call that appends the action's delta (its own rows, never a running action's) to the storage's write log, conditional on the epoch in a cluster, before the action returns; a load is the snapshot plus the log; a snapshot compacts the log | Writes since the last save were lost on a node crash, and storing on every write would store the writes of running actions (ADR 0033). The cost is a storage write per action. [ADR 0048](adr/0048-durable-branches.md) |
