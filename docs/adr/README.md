# Architecture decision records

One file per decision, numbered, half a page at most: context, decision, consequences. The design document is the current state; ADRs are the history of how it got there.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-change-struct-and-capture-module.md) | `Ramal.Change` is the diff struct; the write-side hook is `Ramal.Capture` | accepted |
| [0002](0002-current-branch-carrier.md) | The current branch travels in the process dictionary and in Ash's shared context | accepted |
| [0003](0003-branch-process-lifecycle.md) | Branch process lifecycle: supervisor-level limits, kept discards, config-last storage | accepted |
| [0004](0004-read-patching-hooks.md) | Read patching: where it hooks in and what it does differently from the first design | accepted |
| [0005](0005-write-capture.md) | Write capture: hook, atomic fallback, bulk, notifications and errors | accepted |
| [0006](0006-fingerprints-and-fork.md) | Fingerprints, snapshots and fork | accepted |
| [0007](0007-merge.md) | Merge: claim, check, replay | accepted |
| [0008](0008-postgres-storage.md) | Postgres storage and the codec | accepted |
| [0009](0009-multitenancy-refused.md) | Multitenancy is refused inside a branch | accepted |
| [0010](0010-stored-actors.md) | Stored actors drop sensitive attributes | accepted |
| [0011](0011-branch-aggregates.md) | Aggregates over a branch are computed from the patched rows | accepted |
| [0012](0012-proposals.md) | Proposals are a branch status and a field | accepted |
| [0013](0013-aggregate-delta.md) | Aggregates read only the overlaid rows | accepted |
| [0014](0014-many-to-many-join-resources.md) | Many-to-many join resources |  |
| [0015](0015-inspector-mounting.md) | The inspector is a separate project mounted by a router macro in the host's own live_session | accepted |
| [0016](0016-security-defaults.md) | Security defaults: fail closed, print nothing a branch holds, read storage defensively | accepted |
| [0017](0017-many-to-many-links-in-a-branch.md) | Many-to-many links in a branch | accepted |
| [0018](0018-branch-owner.md) | An optional owner on a branch, and an owner filter for `list/2` | accepted |
| [0019](0019-agent-tools.md) | Branch tools for AI agents, and a context that puts an Ash call in a branch | accepted |
| [0020](0020-read-selects-overlay.md) | A read takes only the overlay entries it can use | accepted |
| [0021](0021-owner-column.md) | The owner is a generated column with an index | accepted |
| [0022](0022-compact-state.md) | The stored state is compact (version 2) | accepted |
| [0023](0023-merge-commit-is-final.md) | A merge whose transaction committed is never reported as failed | accepted |
| [0024](0024-text-sort-order.md) | A text sort inside a branch is byte order, and Ramal does not guess a collation | accepted |
| [0025](0025-relationship-filters-in-elixir.md) | A filter or sort through a relationship the branch changed is evaluated in Elixir | accepted |
| [0026](0026-branch-checked-at-execution.md) | The branch is checked when the action runs, and tasks inherit it | accepted |
| [0027](0027-domain-coverage.md) | A domain a branch cannot cover is refused | accepted |
| [0028](0028-late-binding-queries.md) | A query prepared outside a branch is bound when it runs | accepted |
| [0029](0029-declared-aggregates-in-branches.md) | Aggregates declared on a resource are computed over the branch | accepted |
| [0030](0030-pages-cut-from-the-patched-list.md) | A page is cut from the patched list | accepted |
| [0031](0031-ramal-load.md) | Ramal.load/3 for records the branch changed | accepted |
| [0032](0032-aggregate-filters-and-sorts.md) | Filters and sorts on an aggregate see the branch | accepted |
| [0033](0033-running-actions-hold-their-writes.md) | A running action's writes are its own until it ends | accepted |
| [0034](0034-one-tenant-per-branch.md) | One tenant per branch | accepted |
| [0035](0035-merged-status-in-the-merge-transaction.md) | The merge's transaction stores the merged status | accepted |
| [0037](0037-result-checks-run-on-the-patched-rows.md) | Result checks run on the patched rows | accepted |
| [0038](0038-upserts-in-the-branch-view.md) | Upserts are decided in the branch's view | accepted |
| [0039](0039-relationship-pages-cut-per-source.md) | A relationship page is cut from the patched rows, per source record | accepted |
