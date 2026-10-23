# 0030. Ramal.load/3 for records the branch changed

Status: accepted, 2026-10-23. Issue #103.

## Context

`Ash.load(herd, :paddock)` after the branch moved the herd followed the database's foreign key. In Ash 3.37
(`lib/ash/actions/read/read.ex`) a load onto existing records runs the resource's read action with `initial_data`, and
that path calls `load/6` and then `reselect_and_load/6`, a raw `Ash.DataLayer.run_query/2` for the source attributes.
Neither runs the query's hooks (`before_transaction`, `before_action`, `after_action` are all skipped), and the options
that would skip the reselect (`reuse_values?`) are read from the caller's options before the preparations run
(`sanitize_opts/2` is applied before `for_read/5`), so the preparation cannot set them either. Looking at it from the
relationship side does not help: the destination read only sees the foreign keys the reselect produced.

## Decision

Add `Ramal.load/3` and `Ramal.load!/3`. Outside a branch they are `Ash.load/3`. Inside one they fetch the overlay
entries for the given records (only those keys cross the process boundary), copy the
branch's attribute values onto each record, so a struct read before the write is current, and call `Ash.load/3` with
`reuse_values?: true`, which skips the reselect. The relationship itself is read through the read actions, so it is
patched as any read is. A destroyed record is loaded as it is. Only attributes are copied, so what the caller already
loaded stays.

The plain `Ash.load/3` stays as it was and is documented. A `[:ramal, :read, :unpatched_load]` event was considered
and not added: nothing runs when the reselect happens, and guessing from the destination read would flag loads that
are right.

## Consequences

- A host that loads relationships onto records inside a branch uses `Ramal.load/3`; `Ash.Query.load/2` and a plain
  `Ash.read` with `load:` need nothing.
- The cost inside a branch is one call to the branch process per resource in the list.
