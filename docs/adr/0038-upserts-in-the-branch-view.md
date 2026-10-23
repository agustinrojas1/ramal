# 0038. Upserts are decided in the branch's view

Status: accepted, 2026-10-23. Amends [ADR 0005](0005-write-capture.md).

## Context

An upsert inserts a row or updates the one with the same identity, and only the database knows which. The capture
refused every upsert (`:upsert_unsupported`) because it could not tell, and the refusal read
`changeset.context.private.upsert?`. In Ash 3.37 that flag means different things at different stages:

- `Ash.Changeset.for_create/4` sets it from `opts[:upsert?] || action.upsert?`, and a bulk create sets it for each
  changeset it builds. This is what the action asked for.
- `Ash.Actions.Create.do_run/4` sets it to `true` for **every** create before the `before_action` hooks run, so there it
  says nothing.
- A call-time `Ash.create(changeset, upsert?: true)` reaches only `do_run/4`'s options, which no hook sees.

## Decision

- The capture reads the flag in `change/3`, where it is the action's own, and hands it to the write hook.
- The hook builds the record (`apply_attributes/2`), finds the conflict keys (the `upsert_identity`'s keys, plus the
  tenant attribute under attribute multitenancy unless the identity is `all_tenants?`; the primary key with no
  identity) and looks the row up with a patched read of the branch. A key that is `nil` finds nothing unless the
  identity has `nils_distinct? false`. An identity with a `where` is checked against the new row first.
- A row found is **updated**: the upsert fields of the built record are copied onto it, and so are the update defaults
  unless `touch_update_defaults?: false`; the primary key never. The fields are the action's `upsert_fields`, or what
  AshPostgres sets (`upsert/4`, 2.15): the attributes the changeset set without defaults and keys. The write is
  `:updated` in the overlay, with the base row's fingerprint, so the branch sees the update, the database is unchanged,
  and a base row that changed meanwhile is stale. A row the branch created stays `:created`.
- With no row found it is an ordinary create.
- The log entry stays a `:create`, with `upsert: {identity, fields, found?}` among its opts. The merge replays it with
  `upsert?: true`, that identity and those fields. It forces the branch's key only when `found?` is false: a found row
  has its own key, and forcing the branch's would conflict on the primary key instead of the identity. The fields in the
  log never include the key, so a row that appeared in the base meanwhile is updated without taking the branch's key.
- An `upsert_condition` is refused (`:upsert_unsupported`, with that reason): it is a filter on the existing row that
  may use `upsert_conflict/1`, and a branch cannot evaluate it. So is an identity with a `where` that cannot be
  evaluated for the new row.

## Consequences

- Upserts work in a branch, bulk upserts too once bulk actions do (ADR 0036). An upsert costs one patched read.
- A call-time `upsert?: true` still acts as a plain create. Pass it to `Ash.Changeset.for_create/4` or set it on the
  action.
- The lookup and the write are not atomic. Two processes upserting the same identity at once in one branch can both
  create; the merge then upserts twice and the second updates the first. A row that appears in the base after the
  branch looked is not stale (the branch fingerprinted nothing), and the replayed upsert updates it.
- The merge forgets the staleness check's copy of a row an upsert updated, because the update changed it.
