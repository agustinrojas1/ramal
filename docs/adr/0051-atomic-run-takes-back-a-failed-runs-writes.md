# 0051. An atomic run takes back what a failed run wrote

Status: accepted, 2026-10-24. Builds on [ADR 0033](0033-running-actions-hold-their-writes.md) and [ADR 0048](0048-durable-branches.md).

## Context

A branch has no transaction. When the function given to `Ramal.run/2` raises after some writes, those writes stay in
the branch, so code moved from "run in a transaction and roll back" to "run in a branch" changes meaning on failure.
The workaround, a fork per unit of work discarded on failure, costs a branch and leaves a `:discarded` record each time.
The branch process already takes back the writes of one action that fails (`Server.undo/2`), but only while the action
runs: once it ends, its undos are gone.

## Decision

- `Ramal.run(branch, fun, atomic: true)` (and `run!/3`) asks the branch process for a **savepoint** before `fun` runs:
  `Ramal.Branch.savepoint/1` keeps the overlay, base and `parent_seen` maps (immutable, so keeping them copies nothing),
  the log length and the placeholder counter. If `fun` raises, throws, exits or returns `{:error, _}`, `Server.rollback/2`
  cuts the log back to that length and restores the overlay, base and `parent_seen` entries of the rows the cut entries
  touched (`Ramal.Branch.rollback/2`); the failure then goes on as it would have (re-raised, or returned unchanged).
  Anything else keeps the writes.
- The savepoint is keyed by a monitor of the calling process: its death drops the savepoint, and the branch process does
  not unload for being idle while one is open, since a load from storage would not have it. A restarted process answers
  `:savepoint_lost`.
- A durable branch has already appended the deltas of the actions that ended in `fun`, and the write log only grows. The
  rollback stores a snapshot of the branch, which deletes the deltas it covers (the `Compact` rule), before it answers. A
  snapshot the storage refuses is reported as `[:ramal, :branch, :persist_failed]` with `reason: :rollback` and retried by
  the next compaction.
- The cut is by log length: it assumes one process runs the branch while the atomic run is open. Nothing is locked.

## Consequences

- Cheaper than a fork: one call at the start and, on failure, work proportional to the entries cut.
- The model in `verification/` does not cover the rollback: it takes back writes of actions that ended, which no step
  does. The steps it touches (`Write`, `WriteMore`, `Retract`, `Succeed`, `Down`, `Idle`, `MergerDies`, `Heal`, `Dies`) were
  read against the new code and still hold; extending the model with a `Rollback` step is left for later.
- A fork or a merge taken while an atomic run is open can contain writes that the run then takes back, since the writes of
  actions that ended are the branch's own; use it from one process at a time.
- It does not undo what `fun` did outside the branch, and it does not nest (`:nested_branch`, as for every `run/2`).
