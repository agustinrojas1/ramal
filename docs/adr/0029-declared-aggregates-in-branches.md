# 0029. Aggregates declared on a resource are computed over the branch

Status: accepted, 2026-10-23. Amends [ADR 0004](0004-read-patching-hooks.md) and [ADR 0011](0011-branch-aggregates.md). Issues: #102, #115.

## Context

A resource that declares `aggregates do sum :head_count, :herds, :head end` and loads it inside a branch got the database's
number for rows the branch did not touch, which ignored the branch's herds, and a struct (`Ash.NotLoaded`) for a row the
branch created or changed, because the overlay holds a whole record that was never given the aggregate (#115). The second
is a bug in any reading; the first is the second thing an Ash user tries after `Ramal.aggregate/4`.

## Decision

- After the patch, a helper in lib/ramal/preparation/aggregates.ex gives every aggregate the query loaded the branch's value. It reads the
  aggregate's related records through the patched path (`Ash.load/3` of the relationship path, with the aggregate's own
  query on the last hop, so the branch's creates, updates and destroys and the aggregate's filter apply) and reduces
  them with `Ramal.Aggregate.compute/4`. SQL's edges hold: `nil` is skipped, an empty `sum`, `min`, `max` or `avg` is the
  aggregate's `default`, and a `count` of a field counts the rows where it is not `nil`.
- It recomputes every returned row when the branch holds entries for a resource on the aggregate's path (the destination
  of each hop, and the join resource of a `many_to_many`), and only the rows that came from the overlay (they have no value)
  otherwise. Nothing changes outside a branch, and nothing is recomputed for a row of a path the branch did not touch.
- What cannot be computed keeps the database's value, loaded onto overlay rows so it is a number and never `NotLoaded`, and
  emits `[:ramal, :read, :unpatched_aggregate]`: the kinds `first`, `list` and `custom`, `uniq?`, a join filter, a custom
  read action, a field that is not an attribute, and an aggregate query with a limit, an offset or a distinct. The event is
  emitted for those only; it no longer fires for `count`, `exists`, `sum`, `min`, `max` and `avg`.
- Calculations are not changed here: expression calculations were already evaluated on the patched rows in 0.4.x, and
  a module calculation runs in Elixir on the patched record.

## Consequences

- A read that loads an aggregate over a touched path costs a read of the related rows for each returned row, where the
  database computes the number in one query. Page the read, or use `Ramal.aggregate/4` for one total over a large table.
- The related reads go through the same preparation, so they fingerprint the base rows they return like any read: an
  aggregate over herds adds the herds to the merge staleness check.
- The related reads use the query's actor and `authorize?`, and the aggregate's own `authorize?`, so the policies of the
  destination resource decide which rows count.
- A filter or sort on a declared aggregate (`filter head_count > 10`) was left judged by the data layer on the base rows; [ADR 0032](0032-aggregate-filters-and-sorts.md) closes it.
