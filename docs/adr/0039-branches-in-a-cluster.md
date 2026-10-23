# 0039. Branches in a cluster: global names and storage fencing

Status: accepted, 2026-10-23.

## Context

A branch lived on the node that started its process: the name was in a node-local `Registry`, and the running and
too-large marks were in a node-local ETS table. With the Postgres storage shared by several nodes, each node could load
the same branch and hold its own copy, and the copy that unloaded last overwrote the other's writes. Only a double merge
was prevented (ADR 0035). Running Ramal behind a load balancer, or on a rolling deploy where two versions overlap, hit it.

## Decision

`Ramal.Supervisor` takes `cluster: true` (default `false`; single-node behaviour is unchanged).

- **One process per branch, named with `:global`.** Ramal.Cluster is the `:via` module. A caller on any node finds the
  process, and `GenServer.call/3` and the writer monitors work across nodes. The calls that carry closures (`write/2`,
  `capture/3`) need the same code on every node, as a release has.
- **Fencing.** `Ramal.Storage` gains an optional `claim/2`: it increments the branch's `epoch` and returns the stored
  branch carrying it, in one statement, so a process that has just won the name has the state as of its epoch. Every
  process claims once when it starts, after `:global` gave it the name, never before, so a caller that lost the race does
  not fence the winner. `put/2` and `mark_merged/2` of a branch that has an epoch are conditional on the stored epoch still
  being that one (`UPDATE ... WHERE epoch = $n`), and return `{:error, %Ramal.Error{reason: :fenced}}` otherwise. The epoch
  is a field of `Ramal.Branch`, never stored in `state`, and `nil` without a cluster, which writes as before.
- **A fenced process stops.** On the first refused save (idle unload, propose, reject, discard, shutdown) it emits
  `[:ramal, :branch, :fenced]`, replies the error and stops without saving again. What it held since its last save is
  lost and announced; nothing it holds overwrites the newer state. A merge it runs is refused inside the merge's
  transaction (`mark_merged/2`), which rolls back.
- **Healing a split.** When nodes that registered the same name meet, Ramal.Cluster's resolver keeps the process with the
  higher epoch and tells the other to unload, which the storage then refuses to save. The default resolver would kill it
  and skip `terminate/2`.
- **Storage.** `mix ramal.gen.migration` writes a third migration, `epoch bigint NOT NULL DEFAULT 0` (no table rewrite).
  `Ramal.Storage.Postgres` implements the epoch; so does `Ramal.Storage.ETS`, but its table is one node's, so it only lets a
  cluster of one run for tests. The supervisor refuses to start with `cluster: true` and a storage without `claim/2`.
- **Not moved.** Telemetry stays node-local (the inspector's broadcaster must run on every node over a clustered
  PubSub, documented). The running and too-large marks stay node-local: a process killed for its heap is refused on its
  node, and the other nodes load the last saved state, as they would after a crash. `:branch_rate` counts per node.

## Consequences

- The TLA+ model `verification/tla/Cluster.tla` (3 nodes, splits, heals, a crash) checks that a write a caller was told
  succeeded is in the storage, held by a live process, announced as lost, or lost with a crashed node
  (`NoLostUpdateUnreported`), and that only the process on the storage's epoch changes it (`SingleWriter`). Without the
  guard (`bug-unfenced.cfg`) TLC shows a stale load saving over a newer save. Tests start real nodes with `:peer`.
- A node that joins the cluster registers names a moment before `:global` has told it the others (`:global.sync/0`
  waits for it): a branch it loads then is a split in miniature, and is healed the same way.
- Writes made in a process on the losing side of a split are acknowledged and then lost. Ramal cannot know a node is cut
  off until it saves; the event is the notice. Shortening `idle_timeout` shortens that window.
- A crash of the node holding a branch loses its unsaved writes, as on one node (the durable write log is a separate
  item). The epoch makes the next load safe: the crashed node's process, if it were only partitioned, is fenced.
- The migration is needed only with `cluster: true`; without it nothing reads the column.
