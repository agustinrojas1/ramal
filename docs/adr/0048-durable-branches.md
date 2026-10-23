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
  (`branch_id`, `seq`, `delta`), key `(branch_id, seq)`, cascading from `ramal_branches`, in the last migration of `mix ramal.gen.migration`. ETS: a
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
- In a cluster (`Storage.claim/2`, the `epoch` of ADR 0044) the log is fenced like the snapshot. `append/4` gets the
  branch with its epoch and stores only while the stored epoch is that one: Postgres inserts `FROM ramal_branches WHERE
  epoch = n FOR SHARE`, so a claim, which updates the row, waits for an append that is storing, and an append that comes
  after the claim stores nothing; ETS checks the epoch counter. A refused append fails the action with `:fenced`, the
  process emits `[:ramal, :branch, :fenced]` and stops without saving, and `Capture` does not ask it to undo (that call
  would load the branch again, on the wrong side of a split). A load claims first and reads the log after
  (`writes_after/2` answers `:fenced` if the epoch is no longer the process's), so it reads every delta the earlier
  holder was told was stored and none it was refused; a snapshot of an older epoch deletes no delta. After a crash of
  the node, another node loads the branch with every committed write, which the non-durable cluster cannot. The one gap
  is the lost reply of an append (see above): the earlier holder cannot compact it away any more, so the delta of an
  action it saw fail can reappear on the next holder. `Cluster-durable.cfg` checks `DurableAcked` and
  `SingleLogWriter`, and `bug-unfenced-append.cfg` shows the append without the guard. A delta also holds the count of placeholder keys handed out for generated keys (ADR 0042), which a call
  that is not one of the action's writes bumps; a recovered branch would otherwise give out one again. Nested branches (ADR 0043) compose as
  follows. A nested fork is a durable branch like any other; a delta also holds `seen`, what the fork recorded of its
  parent for the rows it wrote (`parent_seen`), while what it recorded for rows it only read is, like a fingerprint, not
  stored between snapshots. The work a fork gives a parent does not come through `Capture`: `Server.adopt/4` already
  stores the whole parent before it answers, which for a durable parent is a snapshot with its current `wal`, so it
  covers every delta so far and deletes them. It takes only a parent with no action running and the version of the copy
  (`:moved` otherwise), so a delta of the parent's own action is never inside the snapshot nor lost: it is appended after
  it, with a larger `seq`. The scratch copy the replay runs in is not durable and stores nothing. `adopted?/2` reads a
  durable parent as a load does, the snapshot with the log applied. The state version is the lowest that says what the
  branch holds: 2 plain, 3 nested (`parent`, `parent_seen`, `merged_children`), 4 durable, with the nested fields as well
  when it has them; all four are read.
- The TLA+ model has `Durable`: `DurableAcked`, `RecoveredMatchesLog` and `NoHeldPersisted` hold, and
  `bug-durable-held.cfg`, which appends on every write, violates `NoHeldPersisted`.
