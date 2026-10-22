# 0002. The current branch travels in the process dictionary and in Ash's shared context

Status: accepted, 2026-10-22. Issue: #3 (implemented in #3 and #4). Resolves the `[confirm]` in design section 3.

## Context

Hooks must know which branch, if any, the running action belongs to. Design section 3 asked whether Ash's `shared`
context is a better carrier than the process dictionary. Read in Ash 3.37.0:

- Ash has no ambient context. There is no `Ash.set_context`; `Ash.Context.to_opts/2` only copies options that the
  caller passed explicitly. A plain `Ash.update!(herd, ...)` inside `Ramal.run/2`, or an `Ash.read` inside a
  validation, passes none, so `shared` alone cannot reach it.
- Ash does leave the calling process. Relationship loads run in tasks through `Ash.Actions.Read.AsyncLimiter` and
  `Ash.ProcessHelpers.async/2` when the data layer supports `:async_engine` (AshPostgres does) outside a
  transaction, and reads with a `timeout` run in `Ash.ProcessHelpers.task_with_timeout/5`.
  `Ash.ProcessHelpers.get_context_for_transfer/1` transfers only tracer state, so the process dictionary does not
  follow into those tasks.
- Ash copies `context[:shared]` into the queries it builds for those loads
  (`lib/ash/actions/read/relationships.ex`, `Ash.Query.set_context(Map.take(query.context, [:shared]))`).

## Decision

Use both. `Ramal.run/2` stores the branch **id** in the process dictionary (`Ramal.Current`), which reaches every hook
and every nested Ash call in the calling process. The first hook that runs (the read preparation or the write
change) copies the id into the query's or changeset's `shared` context, which Ash carries into the tasks it spawns.
A hook resolves the branch from `shared` first and from the process dictionary second. Only the id is carried, never
the struct, because the struct changes with every write and the branch server owns the truth.

## Consequences

- Relationship loads that Ash runs in tasks still see the branch. Issue #4 tests this with a relationship load.
- Tasks the host starts itself do not inherit the branch; the host calls `Ramal.run/2` inside the task. Unchanged.
- The `shared` bridge only exists once a hook has run, so code that spawns a task before the first Ash call inside
  `run/2` needs `run/2` inside that task.
