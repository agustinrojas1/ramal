# 0023. A merge whose transaction committed is never reported as failed

Status: accepted, 2026-10-23. Amends [ADR 0007](0007-merge.md).

## Context

`Ramal.merge/2` replays the log in a transaction, and then marks the branch `:merged` and persists it. When the storage
refused that write (an outage between the commit and the persist), `merge/2` returned `{:error, %Ramal.Error{reason:
:storage}}` for a merge that had committed. The branch stayed open in storage, a second merge failed as `:stale` (or on
duplicate keys for a create-only branch), and `approve/2` did the same. Separately, every call to a branch process used
`GenServer.call/2`'s five seconds, and the calls that persist the whole branch could exceed it after the commit.

## Decision

- **The commit is final.** After the replay commits, `merge/2` and `approve/2` return `{:ok, %Ramal.Merge.Result{}}`.
  If the storage refuses the `:merged` write, the process keeps the branch as `:merged` (it refuses writes, reads of its
  slice, forks and a second merge with `:not_open`), the result carries the storage error in `persist_failed`,
  `[:ramal, :branch, :persist_failed]` is emitted with `reason: :merged`, and the process writes the branch again at
  each idle timeout, as it does for an idle branch, until the write succeeds and it stops.
- **Calls have explicit timeouts.** Reads and writes wait 5 s; `finish_merge`, `propose`, `reject` and `discard`, which
  persist the whole branch, wait 60 s. A timeout is `{:error, %Ramal.Error{reason: :timeout}}`. When `finish_merge`
  times out after the commit it is treated as a failed persist, not a failed merge.
- **A captured write that times out is taken back.** The write sends its undo to the caller from inside the process;
  after a timeout the caller waits for the process to catch up, and applies the undo if the write ran.
- **A claimed branch cannot be forked** (`:not_open`): a fork of a log about to be replayed would replay it again.

## Consequences

- A host that must know the merged status is durable checks `result.persist_failed`. Until the retry succeeds, a crash of
  the node loses the `:merged` status, and the stored branch is open again; that window is the cost of not blocking the
  caller on a storage that is down.
- A late-answering process can still run a request after its caller gave up. Only captured writes are compensated;
  other calls are idempotent reads or are retried by the caller.
