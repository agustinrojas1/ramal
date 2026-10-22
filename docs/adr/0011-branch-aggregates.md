# 0011. Aggregates over a branch are computed from the patched rows

Status: accepted, 2026-10-22. Issue: #23. Replaces the "0.2 revisits" note in design section 4.4.

## Context

`Ash.count/2`, `Ash.sum/3` and the aggregates declared on a resource are run by the data layer, as SQL, so they never
see the overlay: inside a branch they answer for the base. The read preparation can patch the rows a read returns
(`before_action` and `after_action` hooks), but Ash gives no hook between the aggregate request and the data layer.

## Decision

- **An explicit function:** `Ramal.aggregate(query, kind, field \\ nil, opts \\ [])` for `:count`, `:exists`, `:sum`,
  `:min`, `:max`, `:avg`. Inside `Ramal.run/2` it reads the query through the patched path (so filter, sort, limit and
  offset apply as the query says) and computes the value in Elixir (`Ramal.Aggregate`, pure). Outside a branch it calls
  the matching `Ash` function, so one call site works in both places.
- **SQL semantics for the edges:** `nil` values are skipped, `:sum`, `:min`, `:max` and `:avg` of no values are `nil`,
  `:sum` of decimals is a `Decimal`, `:avg` is a float (Ash types it `:float`), `:min` and `:max` order through
  the runtime sort in Ash.Actions.Sort.
- **Attributes only:** `field` must be an attribute of the resource; anything else raises `ArgumentError` in and out of a
  branch. Aggregates and calculations declared on the resource stay unpatched and keep emitting
  `[:ramal, :read, :unpatched_aggregate]`.
- Not a data-layer wrapper and not a query rewrite: that would reimplement Ash's aggregate engine and break on its next
  release.

## Consequences

- The answer is exact for the branch and costs a read of every matching row. It is not a replacement for the database's
  aggregate on a large table; no speed claim is made (see `bench/`, issue #25).
- Reading through the patched path also fingerprints the base rows it returns, so an aggregate adds those rows to the
  merge staleness check, like any read.
- `first`, `list` and custom aggregate kinds are not covered.
