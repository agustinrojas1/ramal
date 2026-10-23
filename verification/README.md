# Verification

Two formal models of Ramal, and what they prove. Neither reads the Elixir code: each states the rules the code follows,
and tests tie the two together (see [How the models meet the code](#how-the-models-meet-the-code)).

| | what | tool | checked by |
|---|---|---|---|
| [`tla/`](tla) | the life of branches across processes: writes, reads, fork, propose, approve, reject, discard, merge, idle unload, kills, restarts; and a nested fork merging into its parent | TLA+, model-checked with TLC 1.8.0 | `check.sh tla` |
| [`bend/`](bend) | the data rules: overlay entries, what a read in a branch sees, what a merge writes | Bend 2.0.38, also rechecked by its Lean-proved kernel (`--verdict`) | `check.sh bend` |

```sh
verification/check.sh          # both
verification/check.sh tla      # about 4 minutes on 4 cores
verification/check.sh bend     # under a second
```

`check.sh tla` needs Java 11 or later and `tla2tools.jar` at `verification/.tools/` (or `TLA2TOOLS=path`):
`curl -fsSL -o verification/.tools/tla2tools.jar https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar`.
`check.sh bend` needs Bend 2 (`curl -fsSL https://bend-lang.com/install.sh | sh`); `BEND_FLAGS=--verdict` adds the
kernel check, which needs Lean 4.34.0 (`elan toolchain install leanprover/lean4:v4.34.0`). The
[Verification workflow](../.github/workflows/verification.yml) runs both, with `--verdict`.

## TLA+: the branch lifecycle

[`tla/Ramal.tla`](tla/Ramal.tla) models the base as a version per row, storage, one process per branch and the callers.
A step is one message a branch process handles, or what a caller does between two messages, which is how the BEAM
interleaves them; each step names the function it models (`Server.begin_merge/2`, `Capture.rollback/3`, ...).

**Properties** (all hold in [`MC.cfg`](tla/MC.cfg): 2 callers, 1 row, 2 actions, a fork, 1 outside write, 1 heap kill,
and either a node restart or a merger that dies after its commit; 5,457,656 distinct states, depth 24):

| property | meaning |
|---|---|
| `MergeOnce` | a branch's merge transaction commits at most once |
| `OneMerger` | at most one caller is between the claim and the finish of a branch's merge |
| `NoClaimAfterCommit` | a branch whose merge committed is never claimed again |
| `NoPhantomWrite` | a merge, a fork and a proposal never take the write of an action that failed or whose process died |
| `NoLostWrite` | a committed merge replays every write of every action that succeeded in the branch |
| `OverlayMatchesLog` | what reads see (the overlay) is what the log says, so a merge writes what the branch showed |
| `CommitIsFinal` | a merge reported as failed did not commit (ADR 0023) |
| `StatusMonotonic` | a stored status only moves forward, and merged, rejected and discarded are final |

**Bugs it found**, each confirmed by a test that failed before the fix (`test/ramal/running_actions_test.exs`,
[ADR 0033](../docs/adr/0033-running-actions-hold-their-writes.md); `test/ramal/merged_marker_test.exs`,
[ADR 0035](../docs/adr/0035-merged-status-in-the-merge-transaction.md)). A config with the fix switched off shows each one:

| config | what TLC finds without the fix |
|---|---|
| [`bug-pending.cfg`](tla/bug-pending.cfg) | an action writes, another caller forks (or merges, or proposes) the branch, then the action fails or its process dies: its undo is refused, and the fork, merge or proposal keeps a write whose action failed |
| [`bug-overlay.cfg`](tla/bug-overlay.cfg) | two actions write the same row, the first one fails: its undo restores the entry from before both, so reads lose the second write but the log, and so the merge, keeps it |
| [`bug-marker.cfg`](tla/bug-marker.cfg) | the process holding a claimed merge is killed for its heap and reloaded from storage before its watcher marks it: a second caller claims the same branch while the first still holds its claim, and both can commit |
| [`bug-mark-node-crash.cfg`](tla/bug-mark-node-crash.cfg) | the node restarts after a merge committed and before the merged branch was stored: storage has it open, and it is merged again |
| [`bug-mark-merger-crash.cfg`](tla/bug-mark-merger-crash.cfg) | the process running a merge dies after the commit and before `finish_merge`: the claim is released and the branch is merged again |

In the last two, a second merge was refused as `:stale` for every row the branch fingerprinted, and failed on the
primary key for every row it created, unless the caller passed `on_stale: :ignore`; the model lets the caller pass it.
The fix stores the branch as merged inside the merge's transaction (`Commit` with `FixMergedMark`), and the model takes
that write as atomic with the commit, which holds for Postgres storage on the resources' repo. For ETS storage, or
Postgres on another repo, the mark is written just before the commit and outside it (ADR 0035); the model does not
cover a merger killed in that instant.

**Abstractions.** A row is a version number and an action makes one write; nested writes, policies and validations are
not modelled. Storage writes are atomic and may fail; a failed one changes nothing. The Registry, the watcher and the
running marks are modelled as what they decide, not as processes. A node restart loses the writes not yet persisted, as
Ramal documents, so `NoLostWrite` asks only for the writes that survived it. The model is bounded: what TLC proves holds for the
sizes in `MC.cfg`, and larger sizes are left out to keep the check to a few minutes.

## TLA+: a nested fork merging into its parent

[`tla/Nested.tla`](tla/Nested.tla) models the second kind of merge (ADR 0043): a fork made with `nested: true` is claimed,
the parent is copied with its version (`Server.merge_source/1`), the fork's own writes are replayed in the copy, and the
parent takes the copy in one call if its version is unchanged and remembers the fork (`Server.adopt/4`). A write is the
action that made it and who wrote it; the replay may fail, the storage may refuse the parent's persist, and the process
running the merge may die at any step or the node restart. [`MCNested.cfg`](tla/MCNested.cfg) holds with two callers and
five writes (a few thousand states):

| property | meaning |
|---|---|
| `NoDoubleNestedMerge` | no write is in the parent's log twice, however many merges of the fork were tried or died |
| `ParentGetsChildWritesOnce` | once the fork is merged, every write of it that was reported as done is in the parent, once |
| `NoLostParentWrite` | a write to the parent that was reported as done is never lost to a merge of the fork |
| `MergedStaysMerged` | a merged fork is never changed again |

| config | what TLC finds without the guard |
|---|---|
| [`bug-adopt-unversioned.cfg`](tla/bug-adopt-unversioned.cfg) | the parent takes a copy of itself that is not current: a write made since the copy is lost |
| [`bug-no-merged-children.cfg`](tla/bug-no-merged-children.cfg) | the parent does not remember the forks it took: a fork whose merger died after the adoption is merged again, and the parent holds its work twice |
| [`bug-no-reconcile.cfg`](tla/bug-no-reconcile.cfg) | a fork its parent holds stays open when its merger dies: it takes writes the parent never gets. The model found this one; the fix is `Server.adopted?/2` |

The staleness of a fork against its parent is the rule of the first model's fingerprints and is taken as `on_stale:
:ignore` here. The copy and the parent are one process each, and `adopt/4` is atomic and persists before it answers, as
the code does.

## Bend: the data rules

[`bend/model.bend`](bend/model.bend) writes the overlay of `Ramal.Overlay` (an entry per row, combined by the table in
its module doc), the read of one row, an action as one of create, set, add and delete that fails on a row it cannot
apply to, the branch capturing a log of actions, and the merge replaying it on a table of rows.
[`bend/LAWS.bend`](bend/LAWS.bend) states the laws and [`bend/PROOF.bend`](bend/PROOF.bend) proves all twelve:

| law | meaning |
|---|---|
| `branch_reads_replay` | **read(branch) = base ⊕ overlay**: for any log, a read of a row in the branch returns the row the log's actions produce when run on the base |
| `merge_shows_branch` | **the merge writes what the branch showed**: for every row the branch touched and the base did not change since (what the staleness check establishes), the merged row is the one a read in the branch returned |
| `merge_keeps_others` | **a merge loses no edit made outside it**: every row the branch did not touch is, after the merge, what the base holds now |
| `branch_reads_run` | **a nested merge shows what the fork did to what the parent showed**: replaying a log from any honest entry, as the replay in the parent's copy does, reads as the actions run on what the parent showed; `branch_reads_replay` is the case of no entry |
| `capture_honest`, `branch_honest` | an entry never lies about the base: `:created` only for a row the base lacks, `:updated` and `:deleted` only for one it has, after any log |
| `capture_reads` | one captured action changes what reads see exactly as the action changes the row |
| `replay_local`, `capture_local` | a row of the merged table, and a row's overlay entry, depend only on that row and the log's actions on it |
| `fork_copies` | a fork's overlay starts equal to its parent's |
| `key_refl`, `key_sound` | key comparison is equality |

Lean was not needed: Bend expressed every law. Without tactics, a proof is a term built from case analysis, rewriting
and the induction hypothesis; most of the work is the 32-way case split of `capture_reads`, where both sides compute.

**Assumptions** the laws rest on, which the code meets or documents:

- The staleness check is sound: a row whose fingerprint did not change did not change. `:erlang.phash2` can collide, so
  this holds up to a hash collision; and a row read with `select` is not fingerprinted (ADR 0006).
- A row the branch only created has no fingerprint; the hypothesis of `merge_shows_branch` holds for it because the
  replayed create fails on the primary key if someone created the row meanwhile.
- An action does the same thing to the same row at merge as in the branch. Policies, validations and hooks that read
  other rows can decide differently at merge; the merge then fails (`:merge_failed`) rather than write something else.
- Each action writes one row. Writes made by hooks are nested and replayed by their outer action, not modelled here.

**Not covered**: filtering, sorting, `limit` and `offset` of a patched read (`Ramal.Overlay.patch/4`), `diff/2`, and
the relationship and aggregate paths. Those are tested with StreamData properties instead
(`test/ramal/overlay_property_test.exs`, `aggregate_property_test.exs`).

## How the models meet the code

- `test/ramal/model_conformance_test.exs` checks that `Ramal.Overlay` combines writes exactly as the Bend model's
  `put_*` functions do, for all twelve cases, and checks `branch_reads_replay` and `branch_honest` against
  `Ramal.Overlay` on random logs, and that undoing the newest write of a row restores `Ramal.Branch` (the reason a second
  writer of the row is refused while the first action runs).
- `test/ramal/running_actions_test.exs` drives each interleaving TLC found through the real processes.
- The TLA+ steps name the functions they model, so a change to one of those functions is a change to check against the
  model. The Verification workflow runs on changes to them.

What no model covers yet: other processes' reads see a running action's writes (read-uncommitted within a branch);
multitenancy (a branch in one tenant, ADR 0034); Postgres storage specifics such as the owner column; and the inspector.
