# 0007. Merge: claim, check, replay

Status: accepted, 2026-10-22. Issue: #7.

## Context

Design section 7 sketches merge as "check fingerprints, replay the log in one transaction". Replay has to deal with
concurrent writers to the branch, rows created by hooks, actors, and the ids of created rows.

## Decision

- **Claim:** `Ramal.merge/2` first calls `Server.begin_merge/1`. The branch process monitors the caller and, until
  `finish_merge/2` or the caller's death, refuses every other call (write, slice, update, discard, a second merge)
  with `:not_open`. Without this a write could land between the staleness check and the end of the replay and be
  lost when the process stops. On any failure the claim is released and the branch stays open.
- **Check inside the transaction:** the base rows are re-read inside the same `Ash.transact/3` as the replay, with
  `lock: :for_update` where the data layer can (confirmed: AshPostgres.DataLayer.can?/2 accepts `{:lock, :for_update}`
  in 2.15.1). A row that is missing is `:deleted`; one whose fingerprint differs is `:changed`. Rows fingerprinted
  `nil` (read with `select`) are not checked.
- **Replay:** oldest first, with no branch current, skipping entries logged with `nested?: true` since replaying the
  outer action runs its hook again. The actor is the merge `:actor` option when given (even `nil`), otherwise each
  entry's recorded actor; `authorize?` defaults to `true`; the tenant is the one recorded in the entry.
- **Keys:** a replayed create forces the primary key the branch used (`force_change_attribute`), so later entries and
  the branch's diff keep naming the same rows. Updates and destroys load the row by key first (`authorize?: false`,
  as the capture did) and then run the action.
- **Failure:** the first failing entry stops the replay; `Ash.transact/3` rolls everything back; the error is
  `:merge_failed` with `index`, `type`, `resource`, `action` and the Ash `error` in `details`.
- **Result:** `Ramal.Merge.Result` holds `branch` (status `:merged`), `records` (an `Ramal.Overlay` built from what the
  real actions returned), `replayed` and the `stale` rows that `on_stale` let through.
- **Modes:** only `:replay`; anything else raises `ArgumentError`.

## Consequences

- A top-level entry that targets a row created by a hook of an earlier entry cannot be replayed: replay gives the hook's
  row a new id. It fails as `:merge_failed` rather than writing the wrong row.
- The staleness read runs without a tenant, so a resource that requires one fails the merge with an Ash error; multitenancy is
  out of scope for 0.1.
- Rows read with `select` are not checked.
- If the process that called `merge/2` dies mid-replay, the transaction rolls back with it and the monitor releases the
  claim; the branch stays open.
