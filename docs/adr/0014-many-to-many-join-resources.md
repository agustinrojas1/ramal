# 0014. Many-to-many join resources

## Context

DESIGN open question 3 asked where a many_to_many join resource sits in the overlay and said to test it. The Farm test
domain now has `Vet` and a join resource `HerdVet` whose primary key is the pair of foreign keys, so its overlay keys are
tuples. The tests in `test/ramal/many_to_many_test.exs` cover reads, loads, `manage_relationship`, diff, merge, forks and
storage, and checked against Ash 3.37 and AshPostgres 2.15.

## Decision

A join resource is a resource like any other: it gets overlay entries, log entries, fingerprints and diff rows, with a
tuple key when its primary key has several fields. Nothing in the overlay changes for it. Two fixes came out of the
tests:

- An update that changes no attribute is logged (the overlay keeps the row as it was, and `diff/1` leaves it out). Ash
  runs managed relationships and hooks for it, and the rows they write are logged as `nested?: true` because they run
  inside the update. Without the outer entry, merge skipped them and dropped the links. Replaying the update re-runs
  them. This reverses the consequence recorded in ADR 0005.
- `Ramal.Overlay.patch/4` takes a `:replace` function, and the read preparation uses it to keep the
  `__lateral_join_source__` of a base row on the overlay record that takes its place. Ash groups the rows of a
  many_to_many load by it and drops a row without one, so a destination row updated in the branch used to vanish from
  the load.

Two limits stay, documented in DESIGN section 4.1 point 7 and pinned by tests: a many_to_many load does not see links the
branch changed (AshPostgres joins the join table in SQL), and `manage_relationship` decides from that load, so
`:append_and_remove` with a link to remove is refused as a bulk action.

## Consequences

- Merge replays more entries than before for hosts that run no-op updates; each is a read and an update Ash can skip.
- A host that changes links inside a branch reads them through the join resource, or the join relationship, and writes
  them by creating and destroying the join resource directly.
- Making the many_to_many load see links is possible (patch the lateral join in the destination's preparation, or
  load the relationship in Elixir) but needs its own design; it is left for a later version.
