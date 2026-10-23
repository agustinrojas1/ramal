# 0017. Many-to-many links in a branch

Status: proposed, 2026-10-23. Issue: #43. Follows ADR 0014, which left two limits open. A prototype of the
recommendation is in this pull request; docs and changelog change only once it is accepted.

## Context

Inside a branch a many_to_many load does not see links the branch created or destroyed. AshPostgres loads the relationship
with one SQL query that joins the join table in the database (`lateral_join?/4`, `deps/ash/lib/ash/actions/read/relationships.ex`),
so the overlay of the join resource is never consulted. `manage_relationship` decides from that load, so `:remove`
cannot find a link the branch created, `:append` of a vet the branch already linked creates the link twice (the merge
then fails), and `:append_and_remove` with a link to remove is refused: Ash unrelates with `Ash.bulk_destroy/4` on the
join resource (`bulk_delete_unused_unrelate/8`), which calls the data layer directly (`run_batch/8`,
`deps/ash/lib/ash/actions/destroy/bulk.ex`) and so never reaches `Ramal.Capture`. All three are Ash 3.37 and
AshPostgres 2.15.

## Directions evaluated

**Load, A: patch the lateral join in the destination's read preparation.** The destination read of a lateral many_to_many
carries `context.data_layer.lateral_join_source = {source_records, path}`, and the second hop of the path is
`through_query`, a read of the join resource that Ash has already given the join relationship's filter, actor,
`authorize?`, tenant and shared context. When the branch holds entries for the join resource, the preparation reads
`through_query` (which is patched, because the join resource has the same preparation), drops `lateral_join_source`,
filters the destination by the keys the patched join rows name, and after the usual patch tags each row with its source
record's primary key, once per source that links to it, applying `limit` and `offset` per source. When the branch holds
no entry for the join resource nothing changes and Postgres does the join. **Prototyped: works.**
The new module, `lib/ramal/preparation/many_to_many.ex`, is about 100 lines, and the two known-limit tests now assert the right behaviour, plus
tests for several sources at once, the vet's side of the relationship, sort, filter, `limit` and `offset`.

**Load, B: load in Elixir from the patched join resource and the patched destination.** Ash gives no hook before the
relationship loader picks the lateral path, so the only place to do this is the destination's preparation: it is A.
Doing it for every load, not only when the join resource changed, would add a query per load for nothing.

**Load, C: stop Ash choosing the lateral path.** The choice is made from the data layer's capabilities and is the same for
every query of a resource. Not controllable per branch without wrapping the data layer, which ADR 0001 rejected.

**Unrelate, D: keep refusing and improve the error.** There is no `manage_relationship` option that keeps "set"
semantics without a bulk destroy: every `on_missing` that removes (`:unrelate`, `{:destroy, ...}`) is bulk. The error
could only say "call the action once per record", so `:append_and_remove`, the usual way to set a list of vets, could not
be rehearsed in a branch.

**Unrelate, E: capture each destroy of the stream.** `atomic/3` already rules out the atomic strategies, so Ash streams
the join rows (a patched read) and runs one changeset per row. Its `before_action` hooks run, so `Ramal.Capture` writes the
destroy into the overlay there and adds the filter `false` to the changeset, so the DELETE matches no row; AshPostgres
applies `changeset.filter`, and Ash drops the resulting stale-record error from the bulk result.
**Prototyped: works.** `set_vets` destroys the link in the branch, the database is untouched, the diff shows the link as
deleted, and merge replays the outer update.

## Recommendation

Do A and E, in that order of importance, and keep D's refusal for every other bulk action.

A is low risk: it is transparent whenever the join resource is untouched, uses only what Ash hands to the destination
read, and its failure mode is a missing row, caught by tests. E is the riskier half and is scoped to be fail-closed: it
applies only to a destroy that Ash runs for a relationship (`context.accessing_from`) inside a captured action, on
`AshPostgres.DataLayer`; every other bulk action is still refused with `:bulk_unsupported`. If the owner prefers not to
depend on the data layer honouring `changeset.filter`, A alone fixes `:append`, `:remove` and the load, and D covers
the rest.

## Consequences

- Fingerprints: the join rows a load reads are selected by two columns only, so they are not fingerprinted (rows with an
  unselected attribute are skipped); staleness of a link is still detected from the base row a write captured.
- A paged relationship load (`page:` on the load query) is not rewritten and keeps seeing the base links. A through path
  of several hops is not rewritten either.
- E captures only the destroy. The data layer is told to match no row, so `after_action` hooks of that destroy and the
  records it would return do not exist in the branch; `manage_relationship` asks for neither. Bulk updates (a `has_many`
  unrelate) and bulk creates stay refused. A `has_many` `on_missing: :destroy` takes the same path and is untested.
- Ash upgrades: both pieces use behaviour that is observable in 3.37 and not documented as a contract (the shape of
  `lateral_join_source`, `run_batch` swallowing the stale-record error). The tests in `many_to_many_test.exs` fail if
  either changes; E's test asserts the database is untouched.
- If accepted: DESIGN section 4.1 point 7 and decision 20 lose the limits, `CHANGELOG.md` gets a line, and the status
  here becomes accepted.
