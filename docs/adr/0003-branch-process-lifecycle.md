# 0003. Branch process lifecycle: supervisor-level limits, kept discards, config-last storage

Status: accepted, 2026-10-22. Issue: #3.

## Context

Design sections 3, 5 and 6 left details open that the implementation had to settle.

## Decision

- **`idle_timeout` and `max_heap_size` are `Ramal.Supervisor` options**, not per-branch options. A per-branch value
  would be forgotten when the branch is unloaded and loaded again, since the `Ramal.Branch` struct does not carry it.
  `branch/2` takes `name` and `metadata` only; the per-branch `storage` override in design section 5 is dropped for
  the same reason (a lookup by id would not know where to look).
- **Storage callbacks take the storage config as their last argument** (`put(branch, config)`, `fetch(id, config)`,
  `delete(id, config)`, `list(domain, filters, config)`), where the config is the supervisor options that are not
  `Ramal.Supervisor`'s own. The Postgres backend needs its repo from there.
- **A branch is persisted** on creation, on unload (idle or supervisor shutdown), and on discard. Writes between two of
  those exist only in the process. Persisting on every write was rejected: it puts a storage round trip on every
  captured write.
- **`discard/1` keeps the record** with status `:discarded` and an emptied overlay, log and base. That gives
  `:not_open` and `list(domain, status: :discarded)` a meaning and costs one small row.
- **`list/2` returns `{:ok, [branch]} | {:error, error}`**, not a bare list, like every other function, and reads
  storage without loading processes.
- **Too-large detection:** `max_heap_size` kills the process with the untrappable reason `:killed`, so an unlinked
  watcher process monitors each branch server and records a mark in an ETS table owned by the supervisor. Until the
  branch is discarded, use returns `:branch_too_large` and the last persisted state stays in storage. An external
  `Process.exit(pid, :kill)` is indistinguishable and is reported the same way.
- **The log is stored newest first**, so recording a write is O(1); readers reverse it.
- A new error reason `:not_started` for a missing `Ramal.Supervisor`.

## Consequences

- A crash loses writes since the last persist for the ETS backend, and for the Postgres backend too. Hosts that need
  more call for it explicitly later; 0.1 does not promise it.
- Changing `idle_timeout` applies to branches loaded after the change, not to running ones.
