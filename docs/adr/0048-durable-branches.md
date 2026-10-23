# 0048. Durable branches store each action that ended

Status: accepted, 2026-10-23. Amends [ADR 0003](0003-branch-process-lifecycle.md); builds on [ADR 0033](0033-running-actions-hold-their-writes.md). Issue: #166.

## Context

A branch is stored when it is created, proposed, merged, discarded, unloaded and on a clean shutdown (ADR 0003). The
writes in between live in the branch process, and a crash of the node loses them. Storing on every write would put a
running action's writes in storage, and ADR 0033 says they are the action's own until it ends.

## Decision

- **Opt in.** `Ramal.branch(domain, durable: true)`, or `durable: true` on `Ramal.Supervisor` as the default. The flag
  is in the `Ramal.Branch` struct and the stored state (version 4, so a node that does not know the log refuses the state
  and does not drop writes; a branch that is not durable is stored as version 2, byte for byte as before). A fork keeps
  its parent's flag and starts with `wal: 0`.
- **A delta per action.** `Capture` learns from the capture reply that the branch is durable. When the outermost action
  ends well, it calls `Server.commit/1` instead of casting `release`. The process appends one delta to the storage's
  write log and answers; the action returns only then. A delta is the overlay entry and base row of each row the
  action's undos name, the rows whose entry is gone (a created row destroyed), and the action's log entries
  (`Ramal.Branch.delta/2`). Two running actions never hold one row (`:row_busy`), so a delta holds nothing of an action
  that has not ended. A failed or raised action appends nothing. A failed append fails the action with `:storage`,
  and its writes are taken back like any failed action's.
- **Two optional callbacks.** `append(branch, seq, delta, config)` and `writes_after(branch, config)`; `fetch/2` is
  unchanged, so a custom backend keeps working and a durable branch on one without them is refused
  (`:durability_unsupported`). `put/2` of a durable branch deletes the deltas up to `branch.wal`. The snapshot is written
  first, so a failure between leaves deltas `writes_after/2` ignores. Postgres: table `ramal_branch_writes`
  (`branch_id`, `seq`, `delta`), key `(branch_id, seq)`, cascading from `ramal_branches`, in a third migration. ETS: a
  second, ordered table, because the first is scanned whole by `list/3`.
- **Load** is the snapshot with the deltas after its `wal` applied in `seq` order, which is the order the actions ended
  in, not the order they began. Rows differ between concurrent actions, so the result is the same overlay; the log is in
  commit order.
- **Compaction** is a `put` of the branch without running actions' writes, after every 100 appends and after a load
  that applied deltas. It deletes the deltas it covers. An idle unload and a clean shutdown store the branch whole and
  do the same, leaving out an action still running (a durable branch stores nothing of an action that has not ended).
- **A `seq` is never reused.** An append that errors may have been stored (a lost reply), so the process gives up its
  number and compacts at once, which deletes the delta if it exists. If that fails too, the next compaction does.

## Consequences

- One storage write per action, and a snapshot every 100 of them during which the process answers no call:
  [bench/README.md](../../bench/README.md) has the measured cost. Non-durable branches
  are unchanged and call nothing new.
- With Postgres resources, the action's own transaction holds a connection while the process appends over another. A
  pool must have room for both, or the storage can use a repo of its own. The SQL sandbox shares one connection among
  all processes, so there the append waits for the action's transaction and fails; the tests of Ramal that need both run
  on real connections.
- The fingerprint of a row that was read and not written since the last snapshot is not in a delta, so after a crash the
  merge cannot tell that such a row changed. Every row an action wrote has its fingerprint.
- A load reads one row and the deltas after it; `Ramal.list/2` still reads the snapshots only.
- In a cluster (`Storage.claim/2`, the `epoch` of ADR 0044), `append/4` gets the branch with its epoch and must write
  only while the stored epoch is that one, as `put/2` does, or a fenced process could add deltas the new holder never
  sees; its `:fenced` error stops the process the way a refused `put/2` does. This is not in the code, which has no
  epoch yet. Database-generated keys change only what a delta holds. Nested branches (ADR 0043) add writes to a
  parent that do not come through `Capture`, when a child merges into it; for a durable parent those must be appended
  as a delta too, or stored as a snapshot, or a crash after the merge of the child loses them.
- The TLA+ model has `Durable`: `DurableAcked`, `RecoveredMatchesLog` and `NoHeldPersisted` hold, and
  `bug-durable-held.cfg`, which appends on every write, violates `NoHeldPersisted`.
