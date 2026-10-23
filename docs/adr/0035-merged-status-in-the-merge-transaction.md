# 0035. The merge's transaction stores the merged status

Status: accepted, 2026-10-23. Amends [ADR 0023](0023-merge-commit-is-final.md).

## Context

A merge committed its replay, then asked the branch process to mark the branch `:merged` and persist it. Between the
two, the branch was merged in the database and open in storage. If the process running the merge died there, its
monitor released the claim and the branch could be merged again; if the node restarted there, the branch was loaded
open from storage and could be merged again (#143). The TLA+ model in `verification/tla` shows both
(`bug-mark-merger-crash.cfg`, `bug-mark-node-crash.cfg`). A second merge is usually refused as `:stale` or on a primary
key, but not with `on_stale: :ignore`.

## Decision

- `Ramal.Storage` gains an optional callback, `mark_merged/2`: store the branch as merged unless the storage already holds
  it so, then `{:error, %Ramal.Error{reason: :not_open, details: %{status: :merged}}}`. `Ramal.merge/2` calls it as the
  last step inside its transaction, under the claim. `Ramal.Storage.Postgres` does it in one statement
  (`INSERT ... ON CONFLICT DO UPDATE ... WHERE status <> 'merged'`), which joins the transaction when the storage's repo
  is the resources' repo: the merged row commits or rolls back with the replay.
- A merge the mark refuses rolls back and returns that error; the process stops as merged without writing.
- When the process running a merge dies while it holds the claim, the branch process asks the storage first and stops
  as merged if the storage says so; otherwise it releases the claim as before.
- Postgres storage's `put` never replaces a merged row with a branch that is not merged, so a process that missed
  the merge (its merger died while the commit was in flight) cannot store it open again when it unloads.
- `Ramal.Storage.ETS` implements the callback too. It cannot join the transaction, so a merge whose commit fails after
  the mark puts the open branch back.
- After a merge the mark stored, `finish_merge` writes nothing more unless an approval has a decision to add.

## Consequences

- With Postgres storage on the resources' repo, a committed merge is recorded as merged in the same commit: a merger
  that dies or a node that restarts after it cannot merge the branch again. TLC checks `MergeOnce` and
  `NoClaimAfterCommit` with both failures allowed (`MC.cfg`).
- A storage outage now fails the merge before it commits (`:storage`), instead of committing it and reporting
  `persist_failed`. `persist_failed` remains for approvals and for backends without the callback, as ADR 0023 says.
- Postgres storage on another repo, and ETS storage, record the mark before the commit but outside it: a merger killed
  in that instant leaves a branch marked merged whose replay rolled back. ETS storage does not survive a restart anyway.
- A merge holds the branch's row lock from the mark to the commit, and writes the whole branch inside the transaction
  instead of after it.
