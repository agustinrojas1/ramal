# Plan for the remaining known limits

Status: plan, 2026-10-23. Written against Ramal 0.6.1 (main at `1f32373`), Ash 3.37.0, AshPostgres 2.15. Each section below
is meant to become a separate pull request implemented by its own thread. A section gives the root cause (with the Ash
source that causes it), the design, the files to change, the tests that must fail before the change, an ADR outline, the
impact on `verification/`, and the risks. Where a limit cannot or should not be removed, it says why.

ADR numbers: 0036 is taken by the bulk-actions work (the patch below). Give the others numbers in the order they merge,
starting at 0037, and record the next free number in project memory.

## Summary, by user value

| # | Limit (README "Honest limits") | Verdict | Size | TLA+ |
|---|---|---|---|---|
| 1 | Bulk actions refused (and `append_and_remove`, AshAi update/destroy tools) | **Done**, patch ready, unmerged | S | no |
| 2 | Upserts refused | Fix | M | no |
| 3 | Database-generated primary keys refused | Fix (placeholder keys renamed at merge) | L | no (Bend: yes) |
| 4 | Writes since the last save lost on a node crash | Fix, opt-in (durable write log) | L | **yes** |
| 5 | `authorize_results` checks skip rows the branch added | Fix | S | no |
| 6 | Paged relationship loads see the base | Fix | M | no |
| 7 | Multi-hop `through` relationships see the base | Fix | M | no |
| 8 | `first`, `list`, `uniq?`, limited aggregates keep the database value | Fix all but `custom` | M | no |
| 9 | Text sorts use byte order | Fix for AshPostgres (ask Postgres to collate) | M | no |
| 10 | Nested branches (branch of a branch, merge into parent) | Fix | L | **yes** |
| 11 | A branch lives on one node | Fix, opt-in (`:global` registry plus fencing epoch) | XL | **yes** |
| 12 | Merge replay limits: a top-level action on a hook-created row; attributes set outside the action's input | **Done** (ADR 0039) | M | no |
| 13 | Filter through a changed relationship reads more | Narrow (push the unchanged part to SQL) | M | no |
| 14 | `Ash.load/3` on a record the branch changed follows the base foreign key | Needs an Ash change; `Ramal.load/3` stays | - | no |
| 15 | Merge is slower than SQL | Keep replay; optional `mode: :apply` later | L | yes |
| 16 | One tenant per branch | Keep (low value, large refactor) | - | - |
| 17 | Authorization is yours | Optional authorizer hook | S | no |
| - | Not a database branch, OLTP working sets, every resource covered or opted out, notifications dropped, pre-1.0 | By design: keep, reword | - | - |

Suggested order: 1, 5, 2, 6, 7, 8, 12, 3, 9, 4, 13, 10, 17, 11. The small, safe ones go first. Each PR updates the
README limits list, `docs/DESIGN.md`, `usage-rules.md`, the skill and `CHANGELOG.md`, as `CLAUDE.md` requires. After the
last one, release 0.7.0.

---

## 1. Bulk actions: done, waiting to be merged

**Root cause.** The capture change refused `Ash.bulk_*` because the batch path (`run_batch/8` in
`lib/ash/actions/{create,update,destroy}/bulk.ex`) calls the data layer without checking `set_result/2`.

**What was found.** `Ash.Actions.Helpers.split_and_run_simple/7` (`lib/ash/actions/helpers.ex:18`) takes every
changeset that has an `around_action` or `around_transaction` hook out of the batch, and runs it through
`Ash.Actions.{Create,Update,Destroy}.run/4`, the single-action path, which honours `set_result/2`. The capture hook is an
`around_action`, so inside a branch every bulk record already takes the single path once the refusal is removed. The
earlier analysis in #43 looked only at `run_batch/8`, which these changesets never reach.

**The implementation** (commit `ef96878`, closed PR #153, patch in the project files at `limits/0036-bulk.patch`, or `git fetch origin pull/153/head`):

- drops the refusal and adds ADR 0036;
- adds a fail-closed `before_action` guard (`:bulk_unsupported`) for an action the `around_action` did not wrap;
- `test/ramal/bulk_test.exs` (11 tests);
- `append_and_remove` now works and merges;
- the `examples/ash_ai` update tool now works in a branch.

A bulk update or destroy of a query must allow `strategy: [:atomic, :stream]`, because the atomic strategies cannot run
in a branch. AshAi and `manage_relationship` already pass `:stream`. `mix ci` passed with 587 tests.

**To do.**

1. Re-apply on main (`git am limits/0036-bulk.patch`).
2. Fix the one CI failure #153 had. Tests passed, but `mix docs --warnings-as-errors` rejects the backticked hidden
   functions in ADR 0036 (`Ash.Actions.Helpers.split_and_run_simple/7`, `Ash.Actions.Create.run/4`). Write them as
   source paths instead, for example `split_and_run_simple/7` in `lib/ash/actions/helpers.ex`, without the module
   prefix.
3. Run `mix ci`, `mix docs --warnings-as-errors` and `examples/ash_ai` `mix ci`.
4. Open the PR. #43 can be closed by it.

---

## 2. Upserts

**Root cause.** In a branch the capture writes the row Ash built, so it cannot tell whether an upsert would insert or
update. The refusal reads `changeset.context[:private][:upsert?]` in `change/3`.

Confirmed in 3.37:

- `Ash.Changeset.for_create/4` sets that flag from `opts[:upsert?] || action.upsert?` (`changeset.ex:2171`).
- `Ash.Actions.Create.do_run/4` overwrites it with `upsert?: true` for **every** create (`create.ex:175`). At
  before-action time the flag is therefore always true and useless.
- The call-time `Ash.create(cs, upsert?: true)` reaches only `do_run`'s `opts`, which no hook can see.

**Design.** Decide in `change/3`, where the flag is honest: the action's own `upsert?`, an `upsert?: true` given to
`for_create`, or a bulk upsert (bulk sets it per changeset, `create/bulk.ex:486`). Pass `%{identity, fields}` into the
`around` closure. In the write hook:

1. **Find the conflict keys.** They are the `upsert_identity`'s keys (plus the tenant attribute under attribute
   multitenancy, as `commit/3` in `create.ex:290` does), or else the primary key. The values come from
   `apply_attributes/2`. If a key is `nil` and the identity has `nils_distinct?` (the default), there is no conflict, so
   go to step 4.
2. **Look the row up in the branch's view.** Use `Ash.read` with the key filter (plus `identity.where`), `authorize?:
   false`, the branch tenant and `Current.shared_context(id)`, the same way `complete/3` already reads. That read is
   patched and fingerprints the base row.
3. **If a row is found, treat it as an update of that row.**
   - Copy onto it the upsert fields from the built record. The fields are the expanded `upsert_fields`, or, when that
     is nil, what AshPostgres uses (`upsert/4` in `ash_postgres/lib/data_layer.ex:4446`):
     `Map.keys(changeset.attributes) -- changeset.defaults -- keys`.
   - Add the update defaults when `touch_update_defaults?` is set.
   - Never copy the primary key.
   - Store it with `put_write(:updated, ref_of_found_row, …, base_row(found))` and return the found row's key.
4. **If no row is found, treat it as an ordinary create.**
5. **Log entry.** The type stays `:create`, with `upsert: %{identity:, fields:, found?:}` in the opts.

`Ramal.Merge.replay_entry/3` passes `upsert?: true, upsert_identity:, upsert_fields:` to both `for_create` and
`Ash.create`. It forces the key only when `found?` is false. With `found?: true`, forcing the branch's key would conflict
on the primary key instead of the identity. The result is tagged `:updated` when found.

**Still refused.** `upsert_condition`: a runtime filter cannot evaluate `upsert_conflict/1` expressions, so it gets
`:upsert_unsupported` with a precise message. The call-time `Ash.create(cs, upsert?: true)` cannot be detected (see
above) and acts as a create. Document it, and have the guard message tell users to pass `upsert?: true` to
`for_create`.

**Files.** `lib/ramal/capture.ex`, `lib/ramal/merge.ex`, `lib/ramal/storage/codec.ex` (the new opts are plain maps of
existing atoms, which the codec already handles; add a round-trip test), and the docs.

**Tests (Postgres, new identity).** Add `identity :unique_name, [:name]` to `Paddock`, with a migration and a unique
index; AshPostgres needs the index for `ON CONFLICT`. The tests:

- upsert of an existing base row: the branch sees the update, the database is unchanged, and the merge updates that row;
- upsert of a row the branch created: it stays `:created`;
- upsert with nothing there: a create;
- upsert with `upsert_fields` limiting what changes;
- a bulk upsert;
- a merge after the base row changed: it is stale;
- `upsert_condition`: refused.

**ADR outline.** "Upserts decided in the branch's view": context (the flag at each stage), decision (the steps above),
consequences (one patched read per upsert; two concurrent upserts of the same identity from different processes in one
branch can both create; the merge then upserts twice and the second updates the first).

**Risks.** The lookup and the write are not atomic across processes. `Server.capture` serialises per ref, not per
identity. Acceptable, and documented.

---

## 3. Database-generated primary keys

**Root cause.** `written/2` (`capture.ex`) refuses a create whose primary key is `nil` after `apply_attributes/2`.
Integer identity keys (`integer_primary_key`, `generated? true`) and database defaults such as `gen_random_uuid()` only
get a value from the `INSERT`.

**Design: placeholder keys, renamed at merge.**

- **New fields on `%Ramal.Branch{}`:** `next_placeholder` (an integer counter, copied by fork, stored by the codec, and
  defaulting when absent so stored 0.6 branches load) and `placeholders` (`%{{resource, placeholder} => true}`).
- **Placeholder values.**
  - An `Ash.Type.Integer` key gets `-2_147_483_648 + n`. That value fits `int4` and `int8`, so filters that reach
    Postgres do not overflow, and real serial keys are positive.
  - An `Ash.Type.UUID` or `UUIDv7` key gets `Ash.UUID.generate()`.
  - Any other type stays refused (`:database_generated_key`, with a better message).
  - The capture puts the placeholder on the record with `Map.put` before `put_write`, and also on the `before_action`
    changeset with `force_change_attribute`, so the record's after-action hooks see the key.
- **Log.** `opts[:generated_key?] = true` on the create entry.
- **Merge.** `replay/3` keeps a renaming map, placeholder to real key:
  - a create with `generated_key?` is replayed **without** `force_key/3`, and its returned key is recorded;
  - before replaying any later entry, every exact occurrence of a placeholder in `params` and in `opts[:key]` is
    replaced. Strings are matched as well, because form params arrive as text (`"-2147483647"`), and the replacement
    keeps the original form.
  - `Ramal.Merge.Result` gains `keys: %{{resource, placeholder} => real_key}`, and the result records are keyed by the
    real key.
- **Fork** copies the counter, so each branch's placeholders are its own. Two forks may reuse the same placeholder,
  which is harmless because each is renamed at its own merge.

**Files.** `lib/ramal/branch.ex`, `lib/ramal/capture.ex`, `lib/ramal/merge.ex`, `lib/ramal/merge/result.ex`,
`lib/ramal/storage/codec.ex`, the docs.

**Tests.**

- A new Postgres resource with `integer_primary_key :id`, for example `Ramal.Test.Farm.Note`, `belongs_to :herd`, with
  a migration.
- Create, read and update in the branch.
- Create a parent with a generated key and a child that references it by a param, then merge: the child gets the real
  foreign key.
- Update and destroy a placeholder row before the merge.
- A fork.
- Codec round trip.
- Bend: extend `model.bend` with a renaming function and prove that "replay then rename" equals "read in branch" up to
  the renaming.

**ADR outline.** "Placeholder keys for database-generated primary keys": the value ranges and why; renaming by exact
match; consequences: a placeholder can leak to a user before the merge (it is in `diff/1` and in records), which is
documented and visible in `Result.keys`; a hook that stores a placeholder outside a param, such as inside a JSON blob,
is not renamed.

**Risks.** A real attribute that happens to equal a placeholder value is renamed by mistake. That needs an integer near
`-2^31` in user data: very unlikely, documented. A `smallint` key is refused, since its constraint max is under the
range.

---

## 4. Writes lost on a node crash (opt-in durability)

**Root cause.** The overlay and log live in the branch process. They are persisted on create, propose, reject, merge,
discard, idle unload and supervisor shutdown (ADR 0003). A `kill -9` or node crash loses everything in between.

The earlier objection still holds: persisting on every write would store writes of running actions, which ADR 0033
says belong to their action until it ends.

**Design: persist completed actions only, through an append-only write log.**

- **Opt-in** per branch: `Ramal.branch(domain, durable: true)`, stored in the branch so it survives unload; or set it
  for every branch with the `Ramal.Supervisor` option `durable: true`.
- **What is persisted.** When the outermost captured action ends, `Capture.leave/1` currently casts `release`. For a
  durable branch it becomes a **call**, `Server.commit(id)`. The server appends that action's delta (the overlay
  entries, base rows and log entries of its undos, computed from `held.undos`) to storage, then drops the running
  entry and replies. The action returns only after its writes are on disk. Writes of other running actions are never
  in the delta, because each delta is per pid, which keeps ADR 0033 intact.
- **Storage.** New optional callbacks:
  - `append(branch_id, seq, delta, config)`;
  - `fetch/2` returns the snapshot plus the deltas after the snapshot's `seq`;
  - `put/2` of a full snapshot deletes the deltas up to its `seq` (compaction at idle unload and every N deltas).
- **Postgres.** A table `ramal_branch_writes (branch_id uuid, seq bigint, delta jsonb, primary key (branch_id, seq))`,
  added by `mix ramal.gen.migration`. ETS: a second table.
- **Loading.** The snapshot, then the deltas applied in `seq` order with `Branch.put_write/6`. A delta is the codec's
  log-entry and record encoding, so no new serializer is needed.
- **Running mark (ADR 0033).** A durable branch killed unmarked is still treated as too large (unchanged): the heap
  kill is the only way it dies unmarked, and storage is complete for completed actions anyway.

**Cost.** One storage write per action: about 1 ms for Postgres on localhost. Write it into the docs only after
`bench/` measures it, because of the rule on benchmark claims.

**TLA+.** In `Ramal.tla`:

- a `durable` constant;
- `Succeed(c)` appends the action's writes to a new `wal` variable, and `NodeCrash`/`Start` load `store ∘ wal`;
- invariant `DurableAcked`: after any `NodeCrash`, every write in `acked` whose action succeeded is in the loaded
  branch;
- invariant `NoHeldPersisted`: `wal` never holds a write of an action that has not succeeded.

Add `bug-durable-held.cfg` (persist on write instead of on success), which must fail `NoHeldPersisted`. Rerun
`verification/check.sh`.

**Files.** `lib/ramal/branch/server.ex`, `lib/ramal/capture.ex`, `lib/ramal/storage.ex`, `storage/ets.ex`,
`storage/postgres.ex`, `storage/codec.ex`, `lib/mix/tasks/ramal.gen.migration.ex`, `lib/ramal/supervisor.ex`, the
TLA+ files, the docs.

**Tests.**

- Durable branch: write, kill the process with `Process.exit(pid, :kill)` after clearing the too-large mark (as the
  existing restart tests do), or stop the supervisor without `terminate/2`; reload and see the write.
- An action that fails leaves no delta.
- Two concurrent actions: one ends, one crashes; only the first is durable.
- Compaction.
- Postgres and ETS.

**ADR outline.** "Durable branches persist each completed action": context (ADR 0003 and ADR 0033), decision (delta per
completed action, a call not a cast), consequences (the latency of one storage write per action; non-durable branches
are unchanged).

---

## 5. `authorize_results` checks

**Root cause.** `Ash.Actions.Read` runs `run_authorize_results/2` on the data layer's rows **before**
`run_after_action/2` (`read.ex:817-818`), and Ramal patches in its `after_action` hook. The hooks are installed by
authorization at `read.ex:580`, before `run_before_action` at `read.ex:782`. `Ash.Can` adds them for policies that
are partly runtime (`{:filter_and_continue, …}`, `can.ex:1157`, `authorizer.ex:784`).

**Design.** Ramal's last `before_action` hook (`before_data_layer/3` in `lib/ramal/preparation.ex`) already returns the
query Ash goes on with. When the read will be patched (the overlay touches the resource), the hook:

1. moves `query.authorize_results` into `query.context.ramal.authorize_results` and sets the field to `[]`;
2. runs them in its `after_action`, in list order, on the **patched** list, before handing the rows back.

The order and the reduce are exactly `run_authorize_results/2`'s (a 10-line copy, citing `read.ex:3921`). When the
overlay does not touch the resource, nothing moves.

**Files.** `lib/ramal/preparation.ex`.

**Tests.** A policy whose check runs on results: a custom `Ash.Policy.Check` with `strict_check` returning `{:ok,
:unknown}` and a `check/4` that refuses rows with `head > 100`, on a new test resource. Then:

- in a branch that creates a row with `head: 200`, the read is forbidden, as it is in the database (fails today);
- the same read outside a branch is unchanged;
- a branch that does not touch the resource is unchanged.

**ADR outline.** "Result checks run on the patched rows."

**Risk.** The hook relies on `authorize_results` being a public field of `%Ash.Query{}` that is read after
`before_action`. Tests pin it.

---

## 6. Paged relationship loads

**Root cause.**

- `Ash.Query.load(…, rel: Ash.Query.page(q, limit: n))` is read as a lateral join that pages per source record in SQL.
- Ash then trims the extra row per source, in `drop_pagination_extra_per_parent/3` (`read.ex:3156`), before the
  after-action hooks.
- `add_page/7` builds `Ash.Page.Unpaged` from `context.pagination_more_by_source`, and the relationship code turns it
  into one page per source record (`relationships.ex:1352-1390`).
- Ramal patches after all of that, so a branch-created row is missing from its page, a deleted one shortens it, and
  `more?`/`count` are the database's.
- `ManyToMany.rewrite/2` skips paged loads (`paged?/1`).

**Design.** Extend `Ramal.Preparation.Paged` to lateral loads. When the destination resource (or, for a many_to_many,
the join resource) has overlay entries and the query has `page` plus `lateral_join_source`:

1. Read every candidate for all source records in one patched read. That is the lateral filter with no per-source
   limit: the `destination_attribute in ^source_values` filter for a has_many, or the `ManyToMany` link expansion.
2. Sort, group by `__lateral_join_source__`, and per source apply the keyset `after`/`before` filter (already judged by
   `Ash.Filter.Runtime` in `Paged`), the offset, and `limit + 1`.
3. Hand the rows to Ash with `Ash.Query.set_result/2`, as ADR 0030 does for top-level pages. Ash's own
   `drop_pagination_extra_per_parent/3` then computes `more?` per source, and `add_page/7` builds the pages.
4. `count: true` reads the source aggregate `__paginated_<rel>_count__` (`relationships.ex:1675`). Check that
   `Ramal.Preparation.Aggregates` recomputes it, since it is an ordinary `:count`; if it is not, compute it in step 2
   and put it on the source records.

**Files.** `lib/ramal/preparation/paged.ex`, `lib/ramal/preparation/many_to_many.ex` (drop `paged?/1`),
`lib/ramal/preparation.ex`.

**Tests.** `Paddock` `herds` loaded with `page: [limit: 1, count: true]` and `offset`, for two paddocks, after the branch:

- created a herd that sorts first;
- deleted the first herd;
- moved a herd between paddocks.

Then the same for `Herd.vets` (many_to_many), and keyset `after`.

**ADR outline.** "Relationship pages cut from the patched list" (amends ADR 0030).

**Risk.** It uses the shape of `lateral_join_source` and `__lateral_join_source__`, which `ManyToMany` already relies
on, pinned by tests.

---

## 7. Multi-hop `through`

**Root cause.**

- `has_many :teachers, through: [:classrooms, :teachers]` loads with a lateral join whose path has one entry per hop:
  `{entry_query, source_attribute, destination_attribute, relationship}` (`with_lateral_join_query/4`,
  `relationships.ex:379-455`).
- The database walks the intermediate tables, so the branch's rows on them are ignored.
- `ManyToMany.rewrite/2` only matches a two-hop many_to_many path.

**Design.** Generalise `ManyToMany` into a path walker (rename it `Ramal.Preparation.Path`, recorded in DESIGN). When
any resource on the path, or the destination, has overlay entries:

1. Start from the source records' `source_attribute` values. Keep `reach: %{source_pk => MapSet of values}`.
2. For each intermediate entry, read `entry_query` (Ash already hydrated it with the actor, tenant and shared context,
   so it is patched) with `^ref(dest_attr_prev) in ^values`, mapping each row's next-hop attribute back to the sources
   that reached it.
3. On the final hop, drop the lateral join, filter the destination by the values reached, and tag each row with every
   source that reaches it, deduplicated per source.

Many_to_many is the two-hop case of the same walker. Per-source limit and offset are as today, and pages as in #6.

**Semantics check.** Compare with Ash's non-lateral path for `through` on ETS (`Ash.DataLayer.Ets` cannot lateral
join, so Ash walks it in Elixir). The test runs the same load on an ETS copy of the domain and on Postgres outside a
branch, to pin duplicates and order.

**Tests.** Add `has_many :vets, Vet, through: [:herds, :vets]` on `Paddock`, then:

- the branch links a vet to a herd: the paddock's vets include it;
- the branch moves a herd to another paddock: its vets move too;
- the branch destroys the join row;
- the load outside a branch is unchanged.

**ADR outline.** "Relationship paths walked over the branch" (amends ADR 0017).

**Risk.** The same undocumented-shape caveat as #6. Cost is one patched read per hop, and only when a hop's resource
is touched.

---

## 8. Aggregates the branch cannot recompute

**Root cause.** `Ramal.Preparation.Aggregates.supported?/2` and `Ramal.Aggregate.@kinds` know only `count`, `exists`,
`sum`, `min`, `max` and `avg`.

**Design.** The related rows are already loaded through the patched path with the aggregate's own query as the last
hop's query, so they arrive filtered and **sorted** by the aggregate's sort:

- `first`: the field of the first related row, honouring `include_nil?`.
- `list`: the field of every related row in order, with `uniq?` deduplicating keep-first and `include_nil?` honoured.
- `uniq?` on `count`: the count of distinct non-nil values.
- An aggregate query with `limit`/`offset`: applied to the loaded list before reducing. Ash's load already applies them
  per source, so check that first.
- A field that is a calculation: load it on the related rows (`Ash.load` of the calculation) before reducing.
- `join_filter`: walk the path hop by hop with each hop's join filter, using the walker from #7. This can wait.
- **`custom`: stays.** It is a data-layer module (`Ash.Resource.Aggregate.CustomAggregate`) that produces SQL. It keeps
  the database's value and the telemetry event.

`Ramal.aggregate/4` gains `:first` and `:list` for symmetry.

**Files.** `lib/ramal/preparation/aggregates.ex`, `lib/ramal/aggregate.ex`, the test domain (declare `first_herd_name`,
which exists, plus `herd_names` (`list`) and `distinct_heads` (`count uniq?`) on `Paddock`).

**Tests.** For each kind, a branch that creates, updates or deletes a related row changes the value. The existing
`unpatched_aggregate` test moves to a `custom` aggregate. Add a property test: computing an aggregate in Elixir over
rows gives the same result as Postgres over the same rows, for numbers and dates.

**Risk.** A `first`/`list` sorted on text inherits #9.

---

## 9. Text sort order

**Root cause.** Once the overlay touches a resource, the patched list is sorted in Elixir, and strings compare as
bytes (ADR 0024). No Elixir comparator reproduces a Postgres collation.

**Design: let Postgres collate.**

- When a patched sort (or `min`/`max` on a string in `Ramal.aggregate/4`) includes a string attribute, and the
  resource's data layer is AshPostgres, collect the distinct values in the list and run one query on the resource's
  repo:

  ```sql
  SELECT v FROM unnest($1::text[]) AS v ORDER BY v COLLATE "<collation>"
  ```

  Then sort by each value's rank. `<collation>` is the column's: read it once per (table, column) from
  `pg_attribute.attcollation` joined to `pg_collation`, and cache it in `:persistent_term`. Default to the database
  collation.
- `ci_string`/`citext` columns sort on `lower(v)` the way citext does.
- Other data layers keep byte order, as today.

**Cost.** One round trip of `O(distinct strings)` per patched sorted read that sorts on text. Only then; numbers and
dates are unaffected.

**Files.** `lib/ramal/preparation.ex` (the sort step), a new internal `lib/ramal/collation.ex` (add it to DESIGN first
with one line), `lib/ramal/aggregate.ex`.

**Tests.** `Banana`, `apple` and `Ápple` sorted in a branch match the same `ORDER BY` in the database, with the test
database at its default collation, plus a column with `COLLATE "C"`.

**ADR outline.** "Text sorted by the database's collation" (supersedes ADR 0024).

**Risk.** The extra query happens inside the read, so a read inside a transaction uses the same connection (Ecto's
`repo.query/3` in the current process does). The query is read-only, so the rule "never write from a branch" holds.

---

## 10. Nested branches

**Root cause.** By design so far: `Ramal.run/2` refuses nesting (`:nested_branch`), and a fork is a sibling whose merge
replays into the database.

**Design: a child branch merges into its parent.**

- **Creating a child.** `Ramal.fork(parent, nested: true)` (or `Ramal.branch(parent_id)`) creates a fork with `parent:
  %{id, log_length}` recorded on the child.
- **Staleness against the parent.** The child records `parent_seen: %{ref => fingerprint_of_view}` at the first read
  or write of each ref after the fork. For the child's own reads, that is the fingerprint of the overlay record or the
  base row the read returned.
- **`Ramal.merge(child)` when the child has a parent:**
  1. Claim the child (`begin_merge`).
  2. Take a fork of the parent (`fork_source`, which already leaves out running writes) together with the parent's
     `version`, a new counter bumped by every write.
  3. Staleness: a ref in `parent_seen` whose parent view now fingerprints differently is stale (`on_stale` applies).
  4. Replay the child's own entries, the newest `length(child.log) - parent.log_length` ones, oldest first, through the
     real actions inside `Ramal.run(scratch_fork, …)`. The writes are captured into the scratch fork, and validations
     see the parent's view.
  5. `Server.adopt(parent_id, scratch, expected_version, child_id)`: the parent takes the scratch's overlay, log and
     base in one call, if its version is unchanged (otherwise `:stale`, retried once), and records `child_id` in
     `merged_children`.
  6. `finish_merge(:merged)` on the child. A child whose id is in its parent's `merged_children` is refused a second
     merge, as ADR 0035 does for the database.
- **Reentrancy.** `Ramal.run(child, …)` inside `Ramal.run(parent, …)` stays refused. Nesting is a property of the
  branches, not of the call stack.
- **Merging to the database.** `merge` of a parent with open children is allowed; the children then become stale
  against a merged parent and can only be discarded.

**TLA+.** Add a `Child` branch whose parent is `Root`, actions `NestedClaim`, `NestedReplay` (writes go to a scratch
copy) and `Adopt` (atomic, guarded by version), with crashes between steps. Invariants:

- `NoDoubleNestedMerge`;
- `ParentGetsChildWritesOnce`;
- the existing properties still hold for `Root`.

Add `bug-adopt-unversioned.cfg`, which must fail.

**Files.** `lib/ramal.ex`, `lib/ramal/branch.ex`, `lib/ramal/branch/server.ex`, `lib/ramal/merge.ex` (factor replay so
it can run under a branch), `lib/ramal/storage/codec.ex`, the TLA+ files, the docs.

**Tests.**

- A child's writes reach the parent and not the database.
- The parent changed a row the child read: stale.
- The parent wrote an unrelated row: the merge goes through.
- A failed replay leaves the parent untouched (thanks to the scratch fork).
- A second merge is refused.
- The merged parent, merged to the database, carries the child's work.
- `diff/1` of a child shows only its own changes relative to the parent (`diff(child, against: :parent)`).

**ADR outline.** "Nested branches merge into their parent".

**Risk.** The largest semantic surface of this plan. Ship it behind `nested: true` only.

---

## 11. Multi-node

**Root cause.**

- The branch registry is a node-local `Registry` (`Ramal.Supervisor.via/1`).
- The running and too-large marks live in a node-local ETS table.
- With shared Postgres storage, two nodes can each load the same branch: two processes, diverging overlays, and the
  later `put` overwrites the earlier one's writes. Only the double merge is already prevented (ADR 0035).

**Design (opt-in, `Ramal.Supervisor` option `cluster: true`).**

1. **Registration.** Register branch processes with `:global` (`{:via, :global, {Ramal.Branch, id}}`), so every node
   finds the one owner. `Server.call/2` already sends closures (`capture/3`, `write/2`), which needs the same code on
   every node; that is true in a release, so document it. Monitors on writer pids work across nodes.
2. **Fencing.** `:global` resolves name clashes after a netsplit by killing one process, but the loser may already have
   stored state.
   - Add an `epoch` column to `ramal_branches`, bumped atomically when a node loads a branch (`UPDATE … SET epoch =
     epoch + 1 RETURNING epoch`).
   - Every `put`, `mark_merged` and `append` (from #4) is conditional on `epoch = held_epoch`.
   - A refused write stops the process with `[:ramal, :branch, :fenced]`: the writes since its last put are lost but
     never overwrite newer state.
3. **Marks.** The running mark moves into storage as the epoch itself: a process that died without `terminate/2`
   leaves the epoch held, and the next loader bumps it. The too-large mark becomes a storage status `too_large`.
4. **Telemetry and the inspector.** Events stay node-local. `ramal_live`'s broadcaster must run on every node over a
   clustered `Phoenix.PubSub` (document it).

**TLA+.** Two nodes, `:global` modelled as a possibly-split owner map, `epoch` in `store`, `put` guarded by epoch.
Invariants:

- `NoLostUpdateUnreported`: an acknowledged write is either in storage or its process emitted `fenced`/`persist_failed`;
- `SingleWriter`: only the current epoch's writes reach `store`.

`bug-unfenced.cfg` drops the guard and must fail.

**Files.** `lib/ramal/supervisor.ex`, `lib/ramal/branch/server.ex`, `lib/ramal/storage*.ex`, the migration generator,
the TLA+ files, the docs. Test with `:peer` nodes started from ExUnit (`:peer.start_link/1` is in OTP 28) against the
same Postgres.

**ADR outline.** "Branches in a cluster: global names and storage fencing".

**Risk.** Large, and the only item that changes operations for users. Do it last, and keep single-node the default.

---

## 12. Merge replay limits (`Ramal.Merge` moduledoc)

**Root causes.**

- **(a) A top-level action on a row a hook created.** A hook's create is nested and not replayed. Replaying the outer
  action runs the hook again, and the hook's create gets a **new** default key, so a later top-level entry that names
  the branch's key finds nothing.
- **(b) Attributes outside the action's input.** Attributes set on the changeset outside the action's input
  (`Ash.Changeset.change_attribute/3` by the caller between `for_*` and `Ash.create`) are not in `params`, so the
  replay does not set them.

**Design.**

- **(a) Planned keys.** The log already holds the nested creates in order with their keys.
  - During `replay_entry/3` of an outer entry, put a key plan, the list of `{resource, key}` of its nested creates, in
    the process dictionary.
  - Ramal's change still runs during the merge on the guard path (no branch is current). When a plan is present and
    the next planned resource matches, it calls `force_change_attribute` for the primary key and pops the plan.
  - A mismatch stops using the plan; the hook is non-deterministic, and the old behaviour applies.
  - This is a merge-only process flag; outside a merge nothing changes.
- **(b) Recorded changes.** In `change/3` (it runs during `for_*`), snapshot `changeset.attributes` into the `around`
  closure. In the write hook, the attributes that differ from that snapshot and are not explained by the action's own
  later hooks were set by the caller. They cannot be told apart in general, so record the full difference as
  `opts[:forced]` and replay with `force_change_attributes` after `for_*`. Forcing the same value a hook would set again
  is idempotent; a time-based value (`updated_at`) is excluded by skipping attributes that have an `update_default` or
  a `default`.

**Tests.**

- (a) An action whose `after_action` creates a `Move`, followed by a top-level update of that `Move` by key: merge
  succeeds (fails today).
- (b) `change_attribute(:head, 99)` before `Ash.update` in a branch: the merge sets `head` to 99.

**ADR outline.** "Replay keeps hook-created keys and caller-set attributes".

**As built (ADR 0039).** Two differences from the design above. (a) The log's order cannot say which nested creates
belong to which action: a `before_action` hook's create is logged ahead of its action's entry, an `after_action` hook's
after it, and writes of actions in other processes interleave. Every entry therefore carries a random `root` shared by an
action and its hooks, and the plan is the nested creates with the entry's root. (b) The attributes are compared in a
`before_action` hook with `prepend?: true`, so the action's own hooks' changes are not recorded; the defaults Ash applies
at the start of the action are excluded through `changeset.defaults`, not by looking at each attribute's `default`.

---

## 13. Filters through a changed relationship read more

**Root cause.** ADR 0025 takes every conjunct that reaches a changed resource out of the SQL and judges it in Elixir on
all rows the rest of the filter matches.

**Design (narrowing, for `belongs_to`/`has_one` paths of one hop).** Rewrite `paddock.name == "L07"` as:

```
(paddock.name == "L07" and paddock_id not in ^changed_paddock_ids) or paddock_id in ^matching_changed_paddock_ids
```

`changed_paddock_ids` are the overlay keys of `Paddock`; the matching ones are judged in Elixir on the overlay records.
The database stays correct for every paddock the branch did not change. Herds the branch changed are judged by the
overlay as today. `has_many`/`many_to_many` paths (`exists`) keep ADR 0025's behaviour.

**Tests.** The existing relationship-filter tests pass unchanged, plus a telemetry assertion that `base_rows` shrinks.

**ADR outline.** Amends ADR 0025.

---

## 14. `Ash.load/3` on a record the branch changed

**Root cause.** `Ash.Actions.Read.Relationships` reselects the relationship's source attribute with a raw
`Ash.DataLayer.run_query/2` (`reselect_and_load/6`), which runs no preparation (ADR 0031). Nothing in Ramal can see that
query.

**Verdict.** Keep `Ramal.load/3`, and document `reuse_values?: true` as the other fix (already tested in
`preparation_test.exs:651`). To remove the limit, propose upstream that `reselect_and_load` go through the resource's
read action, or skip the reselect for attributes already loaded on records whose metadata says they are current. Only
an Ash change can fix it.

---

## 15. Merge speed

Replay through the actions is the point of the merge. An optional `mode: :apply` (already mentioned in DESIGN §7.1)
would write the final overlay with one bulk upsert and one bulk delete per resource after the staleness check, skipping
the actions. It is faster and skips validations. Leave it unplanned until a user asks; when one does, it needs its own
ADR and a TLA+ variant of `Commit`.

## 16. One tenant per branch

Keying the overlay by `{resource, tenant, key}` touches every module that builds a ref, plus the codec and the TLA+
model. No user has asked for it, and two branches cover two tenants. Keep it, with the reason in the README.

## 17. Authorization is yours

Optionally, add `Ramal.Supervisor` option `authorizer: module` with `authorize(operation, branch, actor) :: :ok |
{:error, reason}`. `Ramal.run/2`, `merge/2`, `propose/2`, `approve/2`, `reject/2`, `discard/1` and `fork/2` call it when
given `actor:`; `Ramal.Tools` passes its actor. Without the option nothing changes, and the README line becomes
"Authorization is yours, or plug in an authorizer".

## Kept by design

These stay in the README, reworded as properties rather than limits:

- **Not a database branch:** no schema changes or branch-local indexes; that is the overlay design.
- **OLTP working sets.**
- **Every resource covered or opted out:** a safety rule.
- **Notifications dropped by default:** a branch must not notify the world; `notify_in_branch?` opts in.
- **Pre-1.0.**
