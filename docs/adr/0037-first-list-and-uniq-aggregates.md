# 0037. `first`, `list` and `uniq?` aggregates are computed over the branch

Status: accepted, 2026-10-23. Amends [ADR 0029](0029-declared-aggregates-in-branches.md).

## Context

ADR 0029 recomputed `count`, `exists`, `sum`, `min`, `max` and `avg` from the branch's related rows and left `first`,
`list`, `uniq?` and a calculation as the field with the database's value (and the `unpatched_aggregate` event). That
meant `first :newest_note, :notes, :title` inside a branch ignored a note the branch created, which reads as a bug.

## Decision

- The related rows already arrive from the patched path filtered **and sorted** by the aggregate's own query, so the
  missing kinds are reductions over that list (`Ramal.Aggregate.compute/5`): `first` is the first value, `list` is every
  value in order. Both skip `nil` unless `include_nil?` is set. `uniq?` keeps the first of each value in a `list` and
  counts distinct non-nil values in a `count`; decimals are compared normalized, as Postgres compares `numeric`. This
  is the semantics of `Ash.DataLayer.Ets` and of AshPostgres, and a test merges a branch and compares the branch's
  numbers with the database's.
- The field of a `first`, `list` or `count` may be a calculation of the related resource. It is loaded onto the related
  rows by the same read, so the preparation of that read evaluates it on the branch's version of a row. `sum`, `min`,
  `max` and `avg` of a calculation keep the database's value, as before: their reduction needs an attribute's type.
- `Ramal.aggregate/4` takes `:first` and `:list`, with `uniq?:` and `include_nil?:`. They depend on the order of the
  rows, so they never use the delta of ADR 0013; they read every matching row through the patched path. Outside a branch
  they are `Ash.first/3` and `Ash.list/3`, and `:first` returns the first row's value even when it is `nil`, as
  `Ash.first/3` does.
- Still unpatched, with the event: `custom` (a data-layer module that produces SQL, there is nothing to reduce), a join
  filter, a custom read action, and a field that is neither an attribute nor a calculation.

## Consequences

- The plan also listed `limit` and `offset` in the aggregate's query. Ash refuses them (`lib/ash/query/aggregate.ex`,
  "Cannot set limit on aggregate query"), so there is nothing to patch.
- The order of a `first` or `list` sorted on text is the order of the branch's comparison, which is byte order until
  the text sort order work lands (ADR 0024).
- The cost is as for the other kinds: a read of the related rows per recomputed row.
