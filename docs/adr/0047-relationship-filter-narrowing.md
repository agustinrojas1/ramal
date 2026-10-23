# 0047. A filter through a changed to-one relationship is narrowed in the data-layer query

Status: accepted, 2026-10-23. Amends [ADR 0025](0025-relationship-filters-in-elixir.md). Issue: #175.

## Context

ADR 0025 takes every conjunct that reaches a resource the branch changed out of the data-layer query and checks it in
Elixir. The database then returns every row the other conjuncts allow: `Herd |> filter(paddock.name == "L07")` after the
branch renamed one paddock read the whole herds table. The database is still right about every paddock the branch did
not change, so most of that read is avoidable.

## Decision

- **Keep a rewritten form of the conjunct in the data-layer query** when it is a `belongs_to` or `has_one` path of one
  hop to a plain relationship (no filter, read action or manual definition, the destination's primary key as
  destination attribute for a `belongs_to`). For a `belongs_to`:
  `(paddock.name == "L07" and (paddock_id is nil or paddock_id not in ^changed)) or paddock_id in ^matching`.
  `changed` are the keys the branch has entries for in the related resource (created, updated, destroyed), `matching`
  those whose branch version satisfies the leaf, judged with `Ash.Filter.Runtime`; a destroyed row counts as matching
  when an all-`nil` record does, which is what the LEFT JOIN gives a missing row. A `has_one` keeps its leaf and adds
  `source_attribute in ^values` for the sources the branch's versions of the related rows point at.
- **The rewrite only narrows.** The conjunct is still removed and checked in Elixir on every row the database returns, so
  an answer never depends on the rewrite being exact, only on it never excluding a row the conjunct accepts. That holds
  for `and` and `or` trees of such leaves. It does not hold under `not` (the rewrite says "false" where the runtime says
  "unknown"), and a `has_one` leaf that a missing related row satisfies (`is_nil(first_herd.name)`) cannot name the
  sources that lost their row, because a destroyed entry holds no record. Those conjuncts, and `exists`, calculations,
  aggregates, paths of more than one hop, leaves that mix the related row with the source's own attributes and
  `has_many`/`many_to_many` paths, keep ADR 0025's behaviour.
- **The prefilter keeps using the conjuncts that reach no changed resource.** A narrowed conjunct judges by the base's
  foreign key and an overlay record has its own.

## Consequences

- The `base_rows` of the `[:ramal, :read, :patch]` event shrinks for a narrowed read, to the rows of the paddocks the
  filter accepts plus the ones the branch changed.
- The query carries the changed keys in two `in` lists, so a branch that changed a very large number of related rows
  sends a long list; the cost still follows what the branch changed.
- The planner reads the related resource's overlay entries once per narrowed leaf.
