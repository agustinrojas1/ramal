# 0053. A guard reports raw Ecto queries on a branched table inside a branch

Status: accepted, 2026-10-24. Builds on [ADR 0002](0002-current-branch-carrier.md) (which branch the calling process is in).

## Context

A branch holds the writes of Ash actions. A raw Ecto query (`Repo.all(from p in "paddocks")`, `update_all`, a join on a link
table) never sees it, so inside `Ramal.run/2` it reads the base data and a number computed from it is wrong with no
error. The limit was documented, but an application of any size has these queries in helpers, and nothing said where.

## Decision

- **`warn_raw_queries: true | :raise` on `Ramal.Supervisor`**, off by default, needs `repo:`. Ramal.RawQueryGuard attaches
  a `:telemetry` handler to the repo's query event. The handler runs in the process that ran the query, so
  Ramal.Current says whether it is inside a branch and `Process.info/2` gives the stack. A query is reported when the
  process is in a branch, the query names the table of a branchable resource of the repo app's `:ash_domains` (the event's
  `source`, or a `FROM`, `JOIN`, `UPDATE` or `INTO` of its SQL), and the stack has no `AshPostgres.DataLayer` frame. That frame is
  how Ash's queries and Ramal's own reads are told from raw ones (Ramal.Ash.data_layer_stack?/1, tripwire in
  `test/ramal/raw_query_guard_test.exs`). The merge runs outside any branch, so it is never reported.
- **A report emits `[:ramal, :raw_query, :detected]` and nothing else.** Ramal logs nothing, as the rest of the library
  does not: the metadata has `branch_id`, `repo`, `table`, `resource`, `query`, `call_site` and `stacktrace`, and the host
  attaches a handler that warns or logs where it wants to. A short one is in `docs/limits.md` and in the `Ramal.Supervisor`
  option doc:

  ```elixir
  :telemetry.attach("warn-raw-queries", [:ramal, :raw_query, :detected], fn _event, _measurements, meta, _config ->
    Logger.warning("raw query on #{meta.table} at #{meta.call_site}\n" <> Exception.format_stacktrace(meta.stacktrace))
  end, nil)
  ```

- **`:raise` cannot raise in the query**: `:telemetry` catches a raising handler and detaches it, and the query has run by
  then. The handler records the first query of the branch and `Ramal.run/2` returns `{:error, %Ramal.Error{reason:
  :raw_query}}` when its function returns (`run!/2` raises it). This is part of the option, stated in the docs. The branch's writes stay.
- **`mix ramal.doctor` also scans `lib/**/*.ex`** line by line for `from`/`join` over a branched resource, an Ecto schema
  over its table or the table name, and a `Repo` call on one. It is a heuristic, labelled so, and never changes the exit status.

## Consequences

- It costs a stack trace for each query on a branched table inside a branch, so it is for development and test.
- The scan misses a query split across lines or built at runtime, and the guard misses nothing it can see but reports no
  raw query on a table whose resource is not in the app's `:ash_domains`.
- A raw query that runs from a `Task` is found through `$callers`, like any branch work (ADR 0026).
- The Ash frame test is not in Ramal.Ash.Contract: if Ash moved the frame the guard would warn about Ash's own queries, and
  no branch read or write would be wrong.
