# 0033. A running action's writes are its own until it ends

Status: accepted, 2026-10-23. Amends [ADR 0003](0003-branch-process-lifecycle.md) and [ADR 0005](0005-write-capture.md).

## Context

The TLA+ model in `verification/tla` found that the branch process treated a captured write as final the moment it was
made, while the action that made it could still fail in a later hook. Another process could merge, propose or fork the
branch in that window and take the write; the failing action's undo was then refused (`:not_open`) and ignored. An
action whose process died mid-way was never undone. And when an action failed after another process had written the
same row, the undo put the older entry back, dropping the newer write from the overlay but not from the log, so reads
and the merge disagreed. Separately, a branch process killed by `max_heap_size` could be loaded again from storage, which
is behind it, before its watcher marked it, so acknowledged writes were lost and a merge claim could be granted twice.

## Decision

- A captured write goes through `Server.capture/3`. The process keeps its undo under the writer's pid, monitors the
  writer, and drops it when the outermost action ends (`Server.release/1`, a cast) or takes it back (`Server.undo/2`).
- While a write is held: `begin_merge` and `propose` wait for it (at most 4 s, then `:timeout`; meanwhile the branch
  takes no new actions, `:not_open` with `status: :closing`); `fork_source` returns the branch without it; a write of the
  same row by another process is refused with the new reason `:row_busy`; the branch does not unload; and if the writer
  dies, the write is taken back, as a database rolls back a dead connection's transaction.
- A process marks itself running in the supervisor's table when it starts and clears the mark in `terminate/2`. A mark
  with no live process means it died without persisting; `ensure_started` then marks the branch too large instead of
  loading it from storage.

## Consequences

- Reads from other processes still see a running action's writes (read-uncommitted inside a branch); only merges,
  proposals, forks and writes to the same row are isolated from them.
- One extra cast and one monitor per captured action; no difference measurable with a 5,000-create microbenchmark.
- A merger that dies after the commit and before `finish_merge` still releases the claim, and the branch can be merged
  again; TLC shows it (`limit-merger-crash.cfg`). It joins the node-crash window of ADR 0023 as a documented limit.
