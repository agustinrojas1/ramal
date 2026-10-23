# 0043. Nested branches merge into their parent

Status: accepted, 2026-10-23. Amends [ADR 0007](0007-merge.md) and [ADR 0035](0035-merged-status-in-the-merge-transaction.md).

## Context

A fork was a sibling: its log started with the parent's, and merging it replayed all of that into the database. A
what-if inside a what-if had nowhere to go: `Ramal.run/2` refuses nesting (`:nested_branch`), and merging the inner
branch meant merging the outer one's work with it.

## Decision

- `Ramal.fork(parent, nested: true)` makes a fork that records `parent: %{id, log_length}`, the length of the log it
  inherited. `Ramal.run/2` still refuses to nest: a nested fork is a branch of its own, run on its own.
- The fork records `parent_seen`, `ref => view`: what it held for each row the first time it read or wrote it, where a
  view is `:base` without an overlay entry and the hash of the entry otherwise. Only the fork's own writes change its
  entries, so that is what the parent held when the fork was made.
- `Ramal.merge/2` of a nested fork claims it, copies the parent with its `version` (`Server.merge_source/1`, which waits
  for the actions running in the parent), compares `parent_seen` with the copy (`on_stale` applies), replays the fork's
  own entries through the real actions in a scratch branch (`Server.start_scratch/2`: a process that is never stored),
  and gives the parent the scratch's overlay, log and base in one call (`Server.adopt/4`). The parent takes it only
  if its `version` is the one copied, persists before it answers, and records the fork's id in `merged_children`. A
  parent that changed meanwhile makes the merge run once more, and then fail as `:stale`.
- A failed replay leaves the parent as it was, because the writes went to the copy. A parent that is not open
  (merged, discarded, proposed, being merged) refuses with `:parent_not_open`: its forks can only be discarded.
- The parent keeps the earliest fingerprint of every base row, which is the fork's when the parent had not seen the
  row, so the staleness check against the database at the parent's own merge is as if the fork had read it there.
- A fork its parent holds in `merged_children` is merged, however its own status was left: when the process that ran the
  merge dies after the parent persisted, and when the fork is loaded from storage. Without it the fork would be open
  and writable, and what it took after the adoption would be lost with the status.
- `diff(fork, against: :parent)` shows the rows the fork wrote itself, compared with what the parent holds now.

## Consequences

- TLC checks the merge in `verification/tla/Nested.tla`: no write is in the parent twice, a merged fork's work is in the
  parent once, and no write to the parent is lost to a merge of the fork. Three configs turn off the version check,
  `merged_children` and the reconciliation, and each fails on the property it protects. The last one was found by the
  model: a fork written to after its merger died.
- `branch_reads_run` in the Bend laws states what the replay in the copy gives for any honest entry the parent holds.
- A nested merge costs a copy of the parent in a process, a replay and one persist of the parent. It is as slow as a
  merge to the database without the transaction, and it holds no lock on the parent while it replays.
- A view is a hash of the overlay entry, so a parent that wrote a row and wrote it back as it was is still stale for a
  fork that saw it. Merging with `on_stale: :ignore` takes it.
- What a fork read through a read that selects some attributes, or through an aggregate, is not recorded, as for the
  database (ADR 0006, ADR 0013).
- The stored state is version 3 for a branch that is a nested fork or holds merged forks, and version 2 for every other
  one, so a node that reads only version 2 keeps reading the branches that never nested.
- The replay in the copy goes through the same replay as a merge to the database, so it has the key plans and the
  caller-set attributes of ADR 0041, bulk actions as records (ADR 0036) and upserts (ADR 0038). The capture change
  applies a key plan on the branch path too, because the copy is a branch. A row whose key the database generates
  (ADR 0042) gets a placeholder of the parent's, the copy's counter becomes the parent's when it adopts the copy, and a
  row the fork created under a placeholder is left out of the staleness check, since the parent may hand out the same
  integer placeholder to a row of its own. `Result.keys` of the fork's merge maps the fork's placeholder to the parent's.
