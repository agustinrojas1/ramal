# 0028. A query prepared outside a branch is bound when it runs

Status: accepted, 2026-10-23. Amends [ADR 0026](0026-branch-checked-at-execution.md), point 4.

## Context

The preparation decided at build time whether a branch was current, and a query prepared outside one got no hooks:
reading it inside `Ramal.run/2` returned base data while every other read saw the branch. ADR 0026 left it because a
`before_action` or `after_action` hook on every query makes Ash refuse an atomic bulk update or destroy of that query
(`lib/ash/actions/update/bulk.ex`, Ash 3.37, lines 101-105), which would change what hosts without a branch get.

## Decision

Outside a branch the preparation adds one `before_transaction` hook. The bulk check does not look at it, and a read
runs `before_transaction` hooks before it reads the query's `before_action` and `after_action` lists
(`do_read/5`, `lib/ash/actions/read/read.ex`), so the hook can add them. When it runs it looks for a current branch
again: with no branch it returns the query untouched; with one it installs the same hooks a query prepared inside
gets, and records the calculations by hand because the hook list Ash is walking is already fixed.

## Consequences

- A prepared query read in a branch sees the branch. The reverse (prepared in a branch, read outside, or under another
  branch) still fails with `:branch_mismatch`.
- Outside a branch the cost is one function call per read, and an atomic bulk update of a prepared query still runs in
  the database (tested).
- A changeset still cannot be bound late: the atomic path never calls a hook, so a changeset built outside a branch and
  run inside it is refused with `:branch_mismatch`.
