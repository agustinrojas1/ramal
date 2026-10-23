# 0036. Bulk actions run record by record inside a branch

Status: accepted, 2026-10-23. Supersedes the bulk part of ADR 0005 and the `append_and_remove` refusal of ADR 0017.

## Context

A branch refused every `Ash.bulk_create/4`, `Ash.bulk_update/4` and `Ash.bulk_destroy/4` with `:bulk_unsupported`,
because the batch path calls the data layer without looking at a result set by a hook. That refusal reached further
than code that calls a bulk action by name: `manage_relationship` with `type: :append_and_remove` unrelates with a bulk
destroy (#43), and AshAi runs every `update` and `destroy` tool as a bulk action on a `limit(1)` query. The workarounds
were a loop of single actions, `:remove` plus `:append`, and a hand-written generic action per tool.

Ash 3.37 does not run every changeset of a bulk action in a batch. `split_and_run_simple/7` in
`lib/ash/actions/helpers.ex`, called by the create, update and destroy bulk modules, takes each changeset that has an
`around_action` or `around_transaction` hook out of the batch and runs it with the `run/4` of the create, update or
destroy action (`lib/ash/actions/{create,update,destroy}`), the functions a single action uses, because such a hook
must wrap the whole operation. Those honour `Ash.Changeset.set_result/2`. The capture change installs exactly such a hook on every changeset
built inside a branch.

## Decision

Inside a branch a bulk action is not refused. Each record runs through the captured single action: it is written to the
overlay, logged as its own entry and replayed by the merge one by one, and the data layer's bulk call gets no records.
Records that fail are reported in the `Ash.BulkResult` and leave nothing behind, as a failing single action does.

A bulk update or destroy of a query chooses its strategy first. Inside a branch neither atomic strategy can run (the
read preparation has a `before_action` hook and `atomic/3` answers `:not_atomic`), so the caller must allow `:stream`
(`strategy: [:atomic, :stream]`); with only `:atomic` Ash refuses the call and nothing is written. AshAi and
`manage_relationship` already allow it.

The capture fails closed: it also adds a `before_action` hook that refuses the action with `:bulk_unsupported` unless the
`around_action` hook wrapped it. If a later Ash ran a branch's changeset without that hook, the action is refused before
the data layer is reached instead of writing the base.

## Consequences

- `append_and_remove` with a link to remove works in a branch, and the AshAi update and destroy tools do too.
- A bulk action in a branch costs a captured write per record; it is not faster than a loop, only shorter to write.
- `transaction: :all` with `rollback_on_error?` rolls back the data layer's transaction, which holds nothing; the records
  that succeeded stay in the branch.
- A bulk update or destroy of a query reads its source with `Ash.stream!/2` in pages of `batch_size` and writes between
  the pages. The pages are cut from the patched list like any paged read (ADR 0030); the source read of the bulk
  action carries `query_for: :bulk_update` as well, so `lib/ramal/preparation/paged.ex` tells a page of the stream from the
  whole-list read of an atomic strategy by the `bypass_max_page_size?` mark that `lib/ash/actions/read/stream.ex` sets.
- `:bulk_unsupported` remains as the guard's reason only.
