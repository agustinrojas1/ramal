# 0005. Write capture: hook, atomic fallback, bulk, notifications and errors

Status: accepted, 2026-10-22; the bulk refusal is superseded by [ADR 0036](0036-bulk-actions-record-by-record.md). Issue: #5. Resolves the `[confirm]` items in design section 4.2.

## Context

Design section 4.2 planned to capture writes in `around_action`, to fall back from atomic updates through
`atomic/3`, to refuse some bulk actions and to suppress notifications. It was checked against Ash 3.37.

## Decision

- **Hook:** `Ramal.Capture` is a global change for create, update and destroy. `around_action` cannot return a result
  without running the callback, and the before-action hooks run inside that callback. So the around hook appends one
  last `before_action` that builds the record with `Ash.Changeset.apply_attributes/2` (which applies defaults, so the
  undocumented `set_defaults/3` is not needed) and calls `Ash.Changeset.set_result(changeset, {:ok, record})`. Create,
  update and destroy then skip the data layer but still run relationship management and the after-action hooks.
- **Atomic updates:** Ash tries `fully_atomic_changeset` first and updates in the database without calling any hook.
  `atomic/3` returns `{:not_atomic, reason}` while a branch is current and `{:ok, changeset}` otherwise, so outside a
  branch the action stays atomic. Ash only falls back for `require_atomic? false`, so the transformer sets it on the
  update and destroy actions of a branchable resource. A resource loses `require_atomic? true` as a guard, also
  outside a branch.
- **Bulk and upsert:** bulk paths call the data layer without reading the result, so every `Ash.bulk_*` is refused with
  `:bulk_unsupported` (the design only refused `return_records?: false`). An action with `upsert? true` is refused with
  `:upsert_unsupported`. The call-time option `upsert?: true` is invisible to hooks (Ash sets it in the context of
  every create when the action runs) and acts as a plain create.
- **Notifications:** `Ramal.run/2` runs `fun` inside `Ash.transaction([], fun, return_notifications?: true)`, which
  opens no database transaction and hands back the queue instead of sending it. Only resources with
  `notify_in_branch? true` get theirs sent afterwards. Default off.
- **Failures:** a captured action that fails or raises takes back the writes it and its hooks' actions made, using the
  undo `Ramal.Branch.put_write/6` returns. A database transaction would have rolled them back.
- **Nested writes:** an action called from a hook of a captured action is logged with `nested?: true`; replaying the
  outer action runs the hook again, so merge skips nested entries.
- **Log entry:** `{action_type, resource, action_name, params, actor, [key:, tenant:, nested?:], at}` with
  `changeset.params`; changes made with `change_attribute/3` outside the action's inputs are not replayed.
- **Errors:** `Ramal.Error` implements `Splode.Error` (class `:invalid`), because Ash turns any other exception added
  to a changeset into a string and the `reason` is lost. `Ramal.Error.find/1` extracts it from an Ash error. `:splode`
  is declared as a dependency; it was already in the tree through Ash.

## Consequences

- An update that changes no attribute writes nothing to the overlay. It is logged since [ADR 0014](0014-many-to-many-join-resources.md),
  which explains why.
- A create with an explicit primary key that exists in the base is not detected, and updating a row the branch already
  deleted resurrects it; a database would raise.
- An undo can overwrite another process's interleaved write to the same row; the branch process serialises writes but
  does not isolate actions.
