# 0051. The staleness check can run without the merge

Status: accepted, 2026-10-24. Experimental: see `docs/STABILITY.md`.

## Context

`Ramal.merge/2` replays the branch's log through the resources' Ash actions. Many hosts put a command layer above Ash
("move this herd"): plain modules that validate across resources, write an audit entry, record what undoes the command,
and then call several Ash actions. A merge replays the low-level writes, so none of that runs again at merge time (#208).
Such a host can use branches for what-if work, but to commit one it would run its own commands again in one transaction
and still keep Ramal's guarantee that the base did not move under the branch. Staleness was only computed inside
`merge/2`, so the host could not have one without the other.

## Decision

Option 1 of the issue: expose the check, and let the host store the outcome. No replay hook.

- `Ramal.stale(branch, opts)` returns `{:ok, []}` or `{:ok, rows}`, each row `%{resource, key, reason: :changed | :deleted}`,
  the rows `merge/2` reports as `:stale`. It calls the same Ramal.Merge.stale_rows/2 that the merge's
  `check_staleness/2` calls, so the two cannot disagree; the only difference is that the lock is a parameter.
- `lock: true` reads with `FOR UPDATE` where the data layer supports it, as the merge does. The locks live as long as
  the caller's transaction, so with `lock: true` the call is refused with `:not_in_transaction` when a resource whose
  data layer locks is not in one: outside a transaction the locks would be gone on return and would protect nothing. The
  default is `lock: false`, a plain read for a preview.
- The branch is not claimed and is unchanged. It waits for running actions like a merge does (`Server.merge_source/1`)
  so a write that may still be taken back is not counted. A branch that is not open is `:not_open`; a nested fork is
  `:nested_fork`, because it merges into its parent and not into the database.
- `Ramal.mark_merged(branch)` claims an open branch (`Server.begin_merge/2`) and stores it as `:merged`
  (`Server.finish_merge/2`), the two calls `merge/2` makes around its transaction, without a replay. `list/2` and the
  inspector then show it as merged and the process stops. It emits `[:ramal, :branch, :mark_merged]`.
- The host's flow is: `Ash.transact(resources, fn -> stale(branch, lock: true), then its commands end)`, then
  `mark_merged/1` after the commit. `discard/1` remains the way to drop the branch instead.
- Both calls are experimental. They are not among the nine stable calls and may change in a minor release.

Option 2 (a replay hook inside `merge/2`) was not taken: it would put a host callback inside the merge transaction and
the claim, and add a mode to the most checked path of the library. The host that wants it can have it by composing the
two calls above.

## How the formal model covers it

`verification/tla/Ramal.tla` is not changed, and neither is any function `verification/model_map.exs` names (the stamps
are unchanged). The new path is made of modelled steps and one step outside the library:

- `stale/2` changes nothing: it is the read-only part of `Commit` (the `Stale(b)` predicate on `db`) and has no step of
  its own. The same function runs in the merge.
- `mark_merged/1` is `Claim` followed by `Finish`: the same `Server.begin_merge/2` and `finish_merge/2`, with a commit
  that is not the model's `Commit`. In the model that commit is another writer, `External`, which writes `db` outside any
  branch, and `MergeOnce` is about the library's replay, not the host's.
- What the model does not give the host is atomicity between the check and the host's commands. That comes from
  `lock: true` and the host's transaction, which `:not_in_transaction` enforces for what it can see. It is checked by
  `test/ramal/stale_check_test.exs` (the locking `SELECT` is issued, a stale row stops the commands, the result equals
  the merge's), not by TLC.

## Consequences

- A host with a command layer can commit a branch through it and keep the staleness guarantee. Validations, audit entries
  and undo records are the host's.
- `mark_merged/1` is a separate step from the host's commit, as a merge without `mark_merged/2` on the storage was
  before ADR 0035. A crash between the two leaves the branch open; the stale check then reports the rows the host's own
  commands changed, which is the signal that the commit happened. The merge's exactly-once guarantee (ADR 0035) does not
  extend to the host's commit.
- The host must not call `merge/2` on a branch it committed itself: after `mark_merged/1` it is `:not_open`, before it
  the replay would write the same changes twice.

## Update: proposed branches (0.10.1, #225)

`stale/2` and `mark_merged` accept a `:proposed` branch as well as an open one, so a host can keep a branch frozen for
review (`propose/2`) and still commit it through its own commands. `stale/2` only reads. `mark_merged(branch,
decided_by: who, reason: why)` claims a proposed branch from `:proposed`, and its `:merged` write adds the approval
`approve/2` records (who, why, when, `replayed: 0`, no stale rows), without a replay. The claim, the persistence and the
failure handling are the merge's own, so `Ramal.tla` is unchanged.
