# 0013. Aggregates read only the overlaid rows

Status: accepted, 2026-10-22. Issue: #28. Supersedes the "computed from the patched rows" part of
[ADR 0011](0011-branch-aggregates.md), whose public function, kinds and edge-case semantics stand.

## Context

ADR 0011 answered `Ramal.aggregate/4` by reading every matching row through the patched path and aggregating in
Elixir. It is exact and costs a read of the table. The benchmark (issue #25) measured what that does to a search that
scores each state with a sum: 5.7 s for 20 forks of a 20,000-row table, against 0.25 s for a delta-table baseline.

## Decision

Inside a branch whose overlay holds rows of the resource, with K the primary keys of those rows:

1. The database aggregates the query with `not (pk in K)` added (`Ash.count/2`, `Ash.sum/3` and the like; `:avg` asks
   for a sum and a count of the non-nil values, so the parts can be joined).
2. The branch reads the query restricted to `pk in K` through the patched path. That returns exactly the branch's
   version of the overlaid rows that match the whole query, policy filters included, with destroyed rows gone and
   created rows present.
3. `Ramal.Aggregate.combine/5` joins the two: counts and sums add, `exists` ors, `:min` and `:max` compare through the
   runtime sort, `:avg` is `(sum + sum) / (count + count)`. Composite keys are matched with one disjunct per key.

Without overlay entries for the resource the data layer's answer is exact, so `Ash.count/2` and friends are called
directly. The read-every-row path of ADR 0011 stays for a query with a `limit`, an `offset` or a `distinct`, where the
aggregate depends on which rows come first, and for a composite key with more than 500 overlaid rows, where the key
filter would be larger than the read.

Confirmed in Ash 3.37 (`lib/ash/actions/aggregate.ex`): the aggregate builds its query with `Ash.Query.for_read/4`, so
the action's policies and preparations apply, but the `before_action` and `after_action` hooks that `Ramal.Preparation`
installs do not run for it. The database part is therefore never patched.

## Consequences

- The cost follows the overlay, not the table. The tree-search case of the benchmark is the measurement.
- **The database's part is not fingerprinted**, so an aggregate no longer adds unread rows to the merge staleness check
  (ADR 0011 said it did). A branch that only aggregated a row and never read or wrote it does not go stale when that
  row changes; its aggregate was true when it was asked. The rows of the overlay are read, and are still checked.
- Two queries instead of one when the overlay is non-empty. For a tiny table and a large overlay the read path would
  be cheaper; no switch was added, since nothing measured needs it.
- A property test compares the delta with the read-based answer for every kind over random branches and filters, and
  fails if the two ever disagree.
