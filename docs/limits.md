# Limits

Ramal is comprehensive, and every limit it has is listed here. Each line is one sentence and links to where the limit is explained in full. The reasons are in the [design document](DESIGN.md) and the [ADRs](adr/README.md).

## The list

- A branch cannot change the schema, add indexes, or promise a query plan, because it is not a database branch ([design, section 1](DESIGN.md)).
- `Ramal.run/2` cannot be nested, so a branch of a branch is a nested fork, run on its own and merged into its parent ([ADR 0043](adr/0043-nested-branches-merge-into-their-parent.md)).
- A branch lives on one node unless you run a cluster with `cluster: true` on `Ramal.Supervisor` and the Postgres storage ([ADR 0044](adr/0044-branches-in-a-cluster.md)).
- In a cluster, a process that lost its branch in a netsplit is fenced at its next save, and unless the branch is durable what it held since its last save is lost and announced with `[:ramal, :branch, :fenced]` ([ADR 0044](adr/0044-branches-in-a-cluster.md)).
- In a cluster, telemetry, the `:branch_rate` window and the heap-kill marks stay on each node, so other nodes do not see them ([ADR 0044](adr/0044-branches-in-a-cluster.md)).
- An aggregate loaded in a branch is recomputed from the branch's rows, but a `custom` aggregate, a join filter or a custom read action keeps the database's value and emits `[:ramal, :read, :unpatched_aggregate]` ([ADR 0029](adr/0029-declared-aggregates-in-branches.md)).
- A filter or sort on an aggregate sees the branch, but when the branch changed a resource on the aggregate's path it reads every row the rest of the filter matches, and for one total over a large table `Ramal.aggregate/4` is cheaper ([ADR 0032](adr/0032-aggregate-filters-and-sorts.md), [ADR 0013](adr/0013-aggregate-delta.md)).
- `Ash.load/3` on a record the branch changed follows the database's foreign key, so use `Ramal.load/3`, and a load inside a read is patched ([ADR 0031](adr/0031-ramal-load.md)).
- A filter or sort through a relationship the branch changed can read more rows than it needs, so keep attribute predicates next to it ([ADR 0047](adr/0047-relationship-filter-narrowing.md), [ADR 0025](adr/0025-relationship-filters-in-elixir.md)).
- A filter through a `belongs_to` or `has_one` is narrowed in the database except under `not`, while `exists`, longer paths and `has_many` paths read every row the rest of the filter allows ([ADR 0047](adr/0047-relationship-filter-narrowing.md)).
- Text sorts inside a branch follow the database's collation, except a `C` column, a resource on another data layer and every key that is not text, which keep their own order, and a keyset cursor on a text sort and a comparison filter on text still compare bytes ([ADR 0045](adr/0045-text-sorted-by-the-databases-collation.md)).
- `Ramal.branch/2` refuses a domain with a resource that has write actions and neither uses `Ramal.Resource` nor sets `branchable? false`, and only the branch's domain is checked, so a resource of another domain is not covered ([ADR 0027](adr/0027-domain-coverage.md)).
- A changeset built under one branch and run under another, or outside a branch and run inside one, fails with `:branch_mismatch`, and a query prepared outside a branch is patched when it is read inside one ([ADR 0026](adr/0026-branch-checked-at-execution.md), [ADR 0028](adr/0028-late-binding-queries.md)).
- Only writes of `create`, `update` and `destroy` actions are held in a branch: a generic action and the outside effects of a hook (an HTTP call, an email, an Oban job, a `Repo` write) run for real, so such hooks should skip themselves when `Ramal.current/0` returns a branch or `Ramal.in_branch?/1` is true ([security notes](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md)).
- Notifications are dropped unless the resource opts in with `notify_in_branch? true` ([ADR 0005](adr/0005-write-capture.md)).
- A database-generated integer or UUID key is a placeholder until the merge renames it to the real key, and other key types, `smallint` keys and composite keys are refused ([ADR 0042](adr/0042-placeholder-keys-for-generated-primary-keys.md)). A sort or keyset page on a generated integer key puts those rows after every real key (before them for `:desc`), as the merge will; a UUID key has no creation order, so a sort by it gives the branch's new rows an arbitrary place until the merge, and a filter by comparison on a placeholder (`id > 5`) sees the negative number. Sort by an inserted timestamp when order matters for a UUID key.
- An upsert with an `upsert_condition` is refused, and `upsert?: true` given only to `Ash.create/2` at call time acts as a create ([ADR 0038](adr/0038-upserts-in-the-branch-view.md)).
- A branch works in one tenant, given at `Ramal.branch/2` ([ADR 0034](adr/0034-one-tenant-per-branch.md)).
- Reads fetch candidate rows and patch them in memory, which is cheap for the rows a session touches and wrong for an analytics table, so Ramal is meant for OLTP-sized working sets ([design, section 4.1](DESIGN.md)).
- Merge replays each change through your action, so it is slower than one SQL statement, which is the price of merging through your own rules ([details](#merge-is-slower-than-sql)).
- Writes since the last save are lost if the node crashes, unless the branch is durable, and a durable branch costs one storage write per action ([ADR 0048](adr/0048-durable-branches.md), [details](#durable-branches-cost-a-write-per-action)).
- After a crash, the merge of a durable branch cannot see a database change to a row the branch read but did not write since its last save, while every row an action wrote keeps its fingerprint ([ADR 0048](adr/0048-durable-branches.md)).
- Bulk actions run record by record in a branch, and a bulk update or destroy of a query must allow `strategy: [:atomic, :stream]` ([ADR 0036](adr/0036-bulk-actions-record-by-record.md)).
- On Ash 3.37 a `through` path with a many_to_many hop is left to the database, which returns nothing for it with or without a branch; Ash after 3.37 expands the hop and the branch sees it. A `through` path with a relationship filter, a limit on a hop, a `distinct` or a `parent` expression is left to the database too, so it shows the branch's changes to rows the database already has but not the rows it created ([ADR 0046](adr/0046-through-paths-walked-over-the-branch.md)).
- Authorization is yours, because anyone who holds a branch id can act on it and Ramal records who decided but never checks ([security notes](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md)).
- The public API may change before 1.0, and the changelog says when it does ([stability](STABILITY.md)).

## Details

### Merge is slower than SQL

Merge runs the replay in one transaction, and each change goes through your real action, so its validations, policies and hooks run again. In the published benchmark a replayed change costs about 0.4 ms, while one set-based `UPDATE` of the same rows is 15 to 64 times faster ([bench/README.md](https://github.com/agustinrojas1/ramal/blob/main/bench/README.md)). A database merge cannot apply your own rules, which is why Ramal pays this cost ([ADR 0007](adr/0007-merge.md)).

### Durable branches cost a write per action

With Postgres on the same host, appending one action's writes to the write log takes 1.1 to 1.7 ms in the published benchmark ([bench/README.md](https://github.com/agustinrojas1/ramal/blob/main/bench/README.md#durable-branches)). The action's own transaction holds a connection while the log is written over another, so the pool needs room for both. The SQL sandbox shares one connection and cannot run the append, so test durable branches with the ETS storage ([ADR 0048](adr/0048-durable-branches.md)).
