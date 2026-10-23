# 0037. Result checks run on the patched rows

Status: accepted, 2026-10-23. Amends [ADR 0004](0004-read-patching-hooks.md).

## Context

A policy with a check that cannot decide in `strict_check` (the runtime half of a policy, for example a check that
needs the loaded row) is installed by `Ash.Can` as an `authorize_results` function on the query, when the action's
policy has `access_type :runtime` or the filter is only necessary (`lib/ash/can.ex`, Ash 3.37). The read action of Ash runs
those functions on the data layer's rows, before the `after_action` hooks (`run_authorize_results/2` and its caller in
`lib/ash/actions/read/read.ex`). Ramal patches the rows in an `after_action` hook, so the checks never saw a record the
branch created, judged a record the branch changed by its database values, and still saw one the branch destroyed. A
branch could show a row that the same read outside it refuses (or drops).

## Decision

- While the overlay touches the resource, the last `before_action` hook moves `query.authorize_results` into the
  query's `ramal` context and leaves the field empty. The functions are installed before any `before_action` hook runs
  (the authorization happens before `run_before_action`), so no check is lost.
- Ramal's `after_action` hook runs them, in list order and each on the rows the one before it returned, on the patched
  rows: after the patch, the sort, the limit and the aggregates, and for a many_to_many load after the rows are
  expanded per source. This is the loop of `run_authorize_results/2`, copied (Ash marks that function `@doc false`).
- A paged read runs them on the page, which the same hook cuts from the patched list (ADR 0030). The list Ramal reads
  to cut the page does not run them, so they run once.
- Without overlay entries for the resource nothing moves and Ash runs the checks as before.

## Consequences

- A check of a policy sees the same rows inside a branch as outside it, overlay records included. A check that drops
  rows drops them from the page or the limited list after the limit, as the database's rows are checked after the limit.
- The checks now run after `after_action` hooks added by earlier preparations, and before those added by later ones.
- The hook depends on `authorize_results` being a field of `%Ash.Query{}` that is read after the `before_action` hooks.
  The tests in `test/ramal/authorize_results_test.exs` pin it, with a Postgres resource and a check that only runs on
  results.
