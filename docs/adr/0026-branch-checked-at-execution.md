# 0026. The branch is checked when the action runs, and tasks inherit it

Status: accepted, 2026-10-23. Amends [ADR 0002](0002-current-branch-carrier.md) and [ADR 0005](0005-write-capture.md). Issues #105, #106, #120.

## Context

A hook decided whether a branch was current when the changeset or query was **built**, and nothing looked again when it
ran. A changeset built outside `Ramal.run/2` and submitted inside it wrote to Postgres; one built inside and submitted
after wrote to the branch. A bulk create with `max_concurrency` builds its changesets in tasks, and a task has no
process dictionary, so the bulk marker was never seen and the rows went to the database. A `Task.async` in `run/2` did
the same. All three come from one fact: the branch lived only in the calling process, and was read once.

Read in Ash 3.37.0: there is no ambient context to set (the `Ash.set_context` the #106 report suggests does not exist), and
`Ash.ProcessHelpers.transfer_context/2` copies only tracer state. What every task Ash or the host starts through `Task`
does carry is `$callers`, the list of processes it was started from.

## Decision

1. The current branch is the id in the calling process, or else the id in the nearest process of `$callers` that has
   one. `Task.async/1`, `Task.async_stream/3`, `Task.Supervisor` and the tasks Ash starts therefore run in the branch of
   the process that started them. `Ramal.run/2` still refuses nesting by the process's own id only, so a task can run
   another branch.
2. A hook records what it found at build time: the id and whether the process or the context supplied it. When the
   action runs, the write hook (in its `around_action`) and the read hook (in its `before_action`) compare that with the
   current branch and return `:branch_mismatch` when they differ. A changeset built with no branch gets a
   `before_action` that refuses when a branch is current at execution. An id carried by `Ramal.context/1` still works
   outside `run/2`, which is its purpose.
3. A captured write from a task that a hook of another captured action started is refused (`:task_in_action`): it would
   be logged on its own, and replaying the outer action runs the hook, and so the task, again.
4. A query prepared outside a branch and read inside it was **not** caught here; [ADR 0028](0028-late-binding-queries.md) fixes it. A guard would be a
   `before_action` on every query, and Ash refuses an atomic bulk update or destroy of a query that has one
   (`lib/ash/actions/update/bulk.ex`), which would change what hosts without a branch get.

## Consequences

- Both snippets of #105 fail with `:branch_mismatch`; #106 fails with `:bulk_unsupported`; a write from a `Task` is
  captured. A process started with `spawn` or `Process.flag`-less machinery, a GenServer cast, or a message to another
  process does not carry the branch: those still write for real. Use `Task`, or call `Ramal.run/2` in the process.
- `Ramal.current/0` inside a task returns the branch. The cost outside a branch is a read of `$callers`, which is empty
  for most processes, and one dictionary read per caller for a task.
- Build and run a changeset in the same place: `AshPhoenix.Form` and similar must be built inside the `run/2` that
  submits them, or both outside.
