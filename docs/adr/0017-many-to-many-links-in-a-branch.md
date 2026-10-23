# 0017. Many-to-many links in a branch

Status: accepted, 2026-10-23. Issue: #43. Follows ADR 0014, which left two limits open. The decision is the load fix;
the bulk unrelate stays refused. That refusal is superseded by [ADR 0036](0036-bulk-actions-record-by-record.md).

## Context

Inside a branch a many_to_many load did not see links the branch created or destroyed. AshPostgres loads the
relationship with one SQL query that joins the join table in the database (`lateral_join?/4`,
`deps/ash/lib/ash/actions/read/relationships.ex`), so the overlay of the join resource was never consulted.
`manage_relationship` decides from that load, so `:remove` could not find a link the branch created and `:append` of a
vet the branch already linked created the link twice (the merge then failed). `:append_and_remove` with a link to
remove is refused: Ash unrelates with `Ash.bulk_destroy/4` on the join resource (`bulk_delete_unused_unrelate/8`),
which calls the data layer directly (`run_batch/8`, `deps/ash/lib/ash/actions/destroy/bulk.ex`) and never reaches
`Ramal.Capture`. All of this is Ash 3.37 and AshPostgres 2.15.

## Directions evaluated

- **A. Patch the lateral join in the destination's read preparation. Chosen.** The destination read of a lateral
  many_to_many carries `context.data_layer.lateral_join_source = {source_records, path}`, and the second hop of the
  path is `through_query`, a read of the join resource that Ash has already given the join relationship's filter,
  actor, `authorize?`, tenant and shared context. When the branch holds entries for the join resource, the preparation
  reads `through_query` (patched, because the join resource has the same preparation), drops `lateral_join_source`,
  filters the destination by the keys the patched join rows name, and after the usual patch tags each row with its
  source record's primary key, once per source that links to it, applying `limit` and `offset` per source. With no entry
  for the join resource nothing changes and Postgres does the join.
- **B. Load in Elixir from the patched join resource and destination.** Ash gives no hook before the relationship
  loader picks the lateral path, so the only place to do it is the destination's preparation: it is A.
- **C. Stop Ash choosing the lateral path.** The choice follows the data layer's capabilities and is the same for every
  query of a resource; changing it per branch means wrapping the data layer, which ADR 0001 rejected.
- **D. Keep refusing the bulk unrelate. Chosen.** No `manage_relationship` option keeps "set" semantics without a bulk
  destroy: every `on_missing` that removes is bulk.
- **E. Capture each destroy of the bulk stream. Prototyped, not adopted.** `atomic/3` already forces the stream
  strategy, whose `before_action` hooks run, so `Ramal.Capture` can write the destroy into the overlay there and add the
  filter `false` so the DELETE matches no row; AshPostgres applies `changeset.filter` and Ash drops the stale-record
  error from the bulk result. It worked end to end (database untouched, diff and merge correct). It is not adopted
  because the invariant "nothing reaches the base" would then rest on the data layer honouring a filter and on Ash
  swallowing an error, neither a documented contract, and the destroy's `after_action` hooks and returned records would
  not exist in the branch.

## Decision

Do A and D. The preparation lives in `lib/ramal/preparation/many_to_many.ex` (`@moduledoc false`) and is called from the
read preparation. A paged relationship load (`page:` on the load query) and a `through` path of several hops are not
rewritten and keep seeing the base links.

## Consequences

- `:remove` finds a link the branch created, `:append` of an already-linked vet creates nothing, and the load sees the
  branch's links from both sides of the relationship. Tests in `many_to_many_test.exs` cover several sources at once,
  sort, filter, `limit` and `offset` per source, and merge.
- `:append_and_remove` with a link to remove is still refused with `:bulk_unsupported`. A host sets the list with
  `:remove` and `:append` actions, or destroys the join rows itself. #43 stays open for this half; E in this record is
  the way to close it if the refusal proves too costly.
- The join rows a load reads are selected by two columns only, so they are not fingerprinted (rows with an unselected
  attribute are skipped); staleness of a link is still detected from the base row a write captured.
- The rewrite uses the shape of `lateral_join_source`, which Ash 3.37 does not document as a contract. The tests fail if
  it changes.
