# Ramal design

Status: draft for milestone 0.1. Written 2026-10-22. This document is the current state of the design; the history of
decisions lives in `docs/adr/`. Where this document and the code disagree, open an issue: one of them is wrong.

Marks: **[confirm]** flags an Ash behaviour the implementer must verify against the locked version (Ash 3.36.x,
AshPostgres 2.15.x) before relying on it, and record the finding in the module doc or an ADR.

## 1. Goal and non-goals

**Goal.** Give an Ash application many cheap, isolated, persistent alternate states of its data ("branches") that
ordinary Ash code can read and write without knowing it is inside one, plus the operations to fork, diff, merge and
discard them. A branch must cost roughly what a process and a map cost, so thousands can be alive at once.

**Non-goals for 0.1.**

- Schema changes inside a branch.
- Branch-local indexes, or any promise about query plans.
- Correct data-layer aggregates and calculations over a branch (they are computed on the base and documented as such).
- Multi-node branches. A branch lives on one node; persistence makes it movable, not distributed.
- A UI. The inspector is a separate package (`ramal_live`) in a later milestone.

## 2. Concepts

**Branch.** `%Ramal.Branch{}`: `id` (UUID string), `name`, `domain` (the Ash domain whose resources it covers; several
domains is a 0.2 question), `status` (`:open | :merged | :discarded`), `base` (fingerprints, section 7), `overlay`,
`log`, `inserted_at`, `metadata` (a map the host uses freely).

**Overlay.** A map from `{resource_module, primary_key}` to one of `{:created, record}`, `{:updated, record}` or
`:deleted`. The record is the full Ash struct as the action left it. The primary key is the value of the resource's
primary key attribute, or a tuple for composite keys. The overlay is the branch's only state that matters for reads.

**Log.** An ordered list of entries `{action_type, resource, action_name, input, actor, opts, at}` recording every
write the branch captured, in order. The log is what `merge/2` replays. The overlay is derived from the log in
principle, but kept materialized because reads need it on every query.

**Fingerprints.** For every base row the branch read or wrote, the hash of its attributes at the moment it was first
touched. Section 7 uses them to detect that the base moved under the branch.

**Change.** `%Ramal.Change{resource, key, kind, changes}` where `kind` is `:created | :updated | :deleted` and
`changes` maps attribute names to `{before, after}`. `diff/1` returns a list of them in log order.

## 3. Process model

- `Ramal.Supervisor` (a `DynamicSupervisor` plus a `Registry` keyed by branch id). The host adds it to its tree:
  `{Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}`.
- `Ramal.Branch.Server` is a `GenServer` per open branch. State is the `%Ramal.Branch{}`. It owns the overlay and the
  log; every write inside the branch is a `GenServer.call` to it, every read asks it for the overlay slice of one
  resource. Reads of the overlay are frequent and small; if they become a bottleneck, the server publishes the
  overlay to an ETS table it owns. Not before the benchmark says so.
- Idle branches unload: after `idle_timeout` (default 5 minutes) the server persists its state through the storage
  backend and stops. `Ramal.branch/2`, `run/2`, `fork/1`, `diff/1`, `merge/2` and `discard/1` all accept a branch id and
  rehydrate the process on demand. The host never needs to know whether the process is alive.
- Memory: `max_heap_size` on the server process, configurable, default generous. A branch that exceeds it is killed
  and its last persisted state remains; the host gets a telemetry event and a `{:error, :branch_too_large}` on next use.
- "Current branch" is process-local. `Ramal.run(branch, fun)` sets it in the process dictionary for the duration of
  `fun`, and also in the Ash context of every query and changeset it can reach. Tasks spawned inside `fun` do not
  inherit it automatically; `Ramal.current/0` and `Ramal.run/2` exist so callers can propagate it explicitly.
  **[confirm]** whether Ash's `shared` context (`Ash.Context`) is a better carrier than the process dictionary for
  nested action calls; use whichever reaches every hook, and document the choice in an ADR.

## 4. Interception: the Spark extension

Resources opt in with `extensions: [Ramal.Resource]`. The extension adds, through a transformer, one global
preparation to every read action and one global change to every create, update and destroy action. It also adds a
`ramal do ... end` section with `branchable? true` (default) so a resource can opt out (a `ramal_branches` table must
never be branchable, for example). A domain-level verifier lists which resources of the domain are branchable, so
`Ramal.branch/2` can refuse a domain with none.

Both hooks are no-ops when no branch is current. A test per hook proves that: the same action, with and without the
extension, produces byte-identical results when no branch is active.

### 4.1 How reads are patched

This is the section that decides correctness. In a read action's preparation, when a branch is current:

1. **Before the data layer:** remember the query's `limit`, `offset` and `sort`, and remove `limit` and `offset` from
   the query that goes to the data layer. The base query keeps its filter, so Postgres still uses its indexes and
   returns only candidate rows. For OLTP-sized working sets this is cheap; for a query that would return a large
   result the host should not be in a branch.
2. **After the data layer:** take the base results and the overlay slice for this resource, then:
   - drop every base row whose key is `:deleted` in the overlay;
   - replace every base row whose key is `:updated` with the overlay record;
   - add every `:created` and `:updated` overlay record that is not already present and that **matches the query's
     filter**, evaluated in Elixir with `Ash.Filter.Runtime` **[confirm exact function and arity]**. An updated row
     that no longer matches the filter is dropped;
   - re-apply the sort in Elixir (`Ash.Sort.runtime_sort/3` **[confirm]**), then the remembered `limit` and `offset`;
   - record a fingerprint (section 7) for every base row that survived or was replaced.
3. **Loads and relationships:** Ash loads relationships through further read actions on the related resource, so they
   go through the same preparation. **[confirm]** that this holds for both the default and the `lazy?` load paths and
   for `Ash.get/3`.
4. **Aggregates and calculations:** data-layer aggregates (`count`, `sum`, `exists`) and calculations with
   expressions are computed on the base and do not see the overlay. 0.1 documents this and emits a
   `[:ramal, :read, :unpatched_aggregate]` telemetry event when a query inside a branch selects one, so a host can
   detect it in tests. 0.2 revisits with runtime evaluation where Ash allows it.
5. **Pagination:** keyset and offset pagination run on the patched list. Correct, not fast. Documented.

### 4.2 How writes are captured

In a create, update or destroy action's change, when a branch is current:

- Use the hook that wraps the data-layer step and lets the change supply the result itself without calling the
  data layer. In Ash 3 this is `Ash.Changeset.around_action/2` **[confirm that the hook may return the result without
  invoking the callback, and the exact return shape]**. If the locked version does not allow skipping the callback,
  the fallback is a manual-action shim installed by the transformer; record the choice in an ADR before writing code.
- All of Ash's own work still happens: argument casting, validations, policies, `before_action` hooks, defaults,
  timestamps. Ramal only replaces "write this to Postgres" with "put this in the overlay", so a branch is a faithful
  rehearsal of the real action.
- The resulting record is built from the changeset (`Ash.Changeset.apply_attributes/2` **[confirm]**). Values the
  database would generate (identity integer keys, database defaults, `now()` set by the data layer) do not exist in
  a branch. 0.1 requires branch-created records to have application-generated primary keys (UUIDs) and returns
  `{:error, %Ramal.Error{reason: :database_generated_key}}` otherwise.
- Destroys mark the key `:deleted`. Updates of a `:created` row stay `:created` with the new record.
- Notifications are returned as the action normally would, so PubSub notifiers in the host fire for branch writes.
  **Decision needed in 0.1:** default to suppressing notifications inside a branch, with an opt-in, because a notifier
  that sends an email on "herd moved" must not fire for a what-if. Document in the ADR.
- **Atomic updates and bulk actions:** the change implements the atomic callback and reports itself as not atomic
  when a branch is current, so Ash falls back to the non-atomic path **[confirm the callback name and the
  not-atomic return value]**. `Ash.bulk_*` with `return_records?: false` inside a branch returns
  `{:error, %Ramal.Error{reason: :bulk_unsupported}}` in 0.1.
- Transactions: an action that opens a data-layer transaction inside a branch still opens one (cheap, empty). Nothing
  is written, so nothing needs rolling back. 0.2 may skip it.

## 5. Public API (0.1)

```elixir
@spec branch(domain :: module, keyword) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
# opts: name, metadata, storage (override), idle_timeout

@spec run(branch | id, (-> result)) :: {:ok, result} | {:error, Ramal.Error.t()}
@spec run!(branch | id, (-> result)) :: result

@spec current() :: Ramal.Branch.t() | nil

@spec fork(branch | id, keyword) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
# the fork is a new branch with a copy of overlay, log and fingerprints; metadata.forked_from = parent id

@spec diff(branch | id) :: {:ok, [Ramal.Change.t()]} | {:error, Ramal.Error.t()}

@spec merge(branch | id, keyword) :: {:ok, Ramal.Merge.Result.t()} | {:error, Ramal.Error.t()}
# opts: actor, authorize? (default true), on_stale (:error | :ignore | (stale_rows -> :continue | :abort)), mode (:replay)

@spec discard(branch | id) :: :ok | {:error, Ramal.Error.t()}

@spec get(id) :: {:ok, Ramal.Branch.t()} | {:error, Ramal.Error.t()}
@spec list(domain, keyword) :: [Ramal.Branch.t()]   # status filter; from storage, not from the registry
```

`Ramal.Error` has `reason` (an atom from a documented list), `message`, and `details` (a map). Reasons in 0.1:
`:not_found`, `:not_open`, `:stale`, `:database_generated_key`, `:bulk_unsupported`, `:branch_too_large`,
`:no_branchable_resources`, `:storage`.

## 6. Persistence

`Ramal.Storage` is a behaviour: `put(branch)`, `fetch(id)`, `delete(id)`, `list(domain, opts)`. Two implementations:

- `Ramal.Storage.ETS`: a named table owned by `Ramal.Supervisor`. Default in tests and development. Lost on restart.
- `Ramal.Storage.Postgres`: one table `ramal_branches` (`id uuid pk, domain text, name text, status text, state jsonb,
  inserted_at, updated_at`). `mix ramal.gen.migration` writes the migration into the host's repo. Requires AshPostgres
  (or at least Ecto SQL); the module compiles only when it is present.

Serialization: overlay records are stored as `%{"resource" => "Elixir.MyApp.Herd", "key" => ..., "op" => "updated",
"attrs" => %{...}}` with attribute values dumped through their Ash types (`Ash.Type.dump_to_embedded/3`
**[confirm]**) and loaded back with `Ash.Type.cast_stored/3` **[confirm]**. The log stores inputs as given; actors are
stored as whatever the host's `Ramal.Actor` serializer returns (default: the actor's primary key and resource name,
rehydrated on merge by a host callback; without a callback, merge requires an explicit `actor:` option).

## 7. Staleness and merge

Every base row a branch reads or writes gets a fingerprint: `:erlang.phash2` of its attribute map at first touch,
keyed by `{resource, key}`. On `merge/2`:

1. Refuse unless `status == :open`.
2. Re-read every fingerprinted row from the base (one query per resource, `filter: key in ^keys`). A row whose hash
   differs, or that no longer exists, is stale.
3. Apply `on_stale`: `:error` (default) returns `{:error, %Ramal.Error{reason: :stale, details: %{rows: [...]}}}`;
   `:ignore` continues; a function receives the stale rows and returns `:continue` or `:abort`.
4. Inside one data-layer transaction, replay the log in order through the real actions with the real data layer
   (no branch current), with the given `actor` and `authorize?`. Any failure aborts the transaction and returns
   `{:error, ...}` with the failing log entry's index. Validations run again, so a branch that was valid against a
   base that has since moved can legitimately fail here; that is the feature.
5. Mark the branch `:merged`, persist, stop the process. Return a `Ramal.Merge.Result` with the records the replay
   produced, keyed like the overlay.

`mode: :replay` is the only merge mode in 0.1. A future `:apply` mode would write the overlay's final state directly,
skipping action logic; it is faster and less safe, and needs its own ADR.

## 8. Fork and diff

- `fork/2` copies overlay, log and fingerprints into a new branch. Both branches share the base; neither sees the
  other. Persistent data structures make the copy cheap; the log is a list and gets shared structurally.
- `diff/1` walks the overlay: for `:updated`, compare the overlay record with the base row as the branch first saw it
  (kept alongside the fingerprint, so diff never queries the base); for `:created`, every attribute is `{nil, value}`;
  for `:deleted`, `{value, nil}`. Output order is the log order of first touch.

## 9. Telemetry

Events, all with `%{branch_id, domain}` metadata:

`[:ramal, :branch, :create]`, `[:ramal, :branch, :fork]`, `[:ramal, :branch, :unload]`, `[:ramal, :branch, :load]`,
`[:ramal, :branch, :discard]`, `[:ramal, :branch, :too_large]`, `[:ramal, :merge, :start | :stop | :exception]` (span),
`[:ramal, :read, :patch]` with measurements `%{base_rows, overlay_rows, result_rows, duration}`,
`[:ramal, :read, :unpatched_aggregate]`, `[:ramal, :write, :capture]` with `%{action_type, resource}`.

## 10. Test domain

`test/support/farm/`: domain `Ramal.Test.Farm` with three resources on `Ramal.TestRepo` (AshPostgres), all with UUID
primary keys and timestamps:

- `Paddock`: `name`, `hectares`, `capacity_head` (integer).
- `Herd`: `name`, `head` (integer), `belongs_to :paddock`.
- `Move`: `belongs_to :herd`, `from_paddock_id`, `to_paddock_id`, `moved_on` (date).

Actions: `Herd.move(to_paddock_id)` with a validation "destination capacity not exceeded" that reads the
destination's herds (so a branch must see its own earlier moves for the validation to be right), creating a `Move`
in an `after_action`. `Paddock` has an aggregate `head_count` (sum of herds' head) to document the unpatched-aggregate
behaviour with a test. One policy on `Herd` (only `%{role: :admin}` may move) to prove policies run inside a branch.

The domain mirrors the first real user of Ramal (an agricultural operations app) and stays in English.

## 11. Open questions

1. Several domains per branch, or one branch per domain? 0.1: one domain. Revisit when a real host needs more.
2. Should `run/2` be reentrant (a branch inside a branch)? 0.1: no, `{:error, :nested_branch}`.
3. Where do many-to-many join resources sit in the overlay? They are resources, so they get overlay entries like any
   other; test it.
4. Does the read preparation need to handle `Ash.Query.select` for load-bearing attributes (the key must always be
   selected to patch)? Probably yes: ensure the primary key is selected.
5. Should fingerprints cover rows read through relationship loads? Yes if cheap; measure.

## 12. Decision log (summary; details in `docs/adr/`)

| # | Decision | Why |
|---|---|---|
| 1 | Hooks (preparation + change) instead of a wrapping data layer | A wrapping data layer breaks every tool that checks `data_layer(resource) == AshPostgres.DataLayer` (migrations, codegen) and must mirror AshPostgres' DSL. Hooks leave the resource's data layer untouched. |
| 2 | One process per branch | Isolation, lifecycle and limits come from the runtime for free. |
| 3 | Overlay materialized, log authoritative for merge | Reads need the overlay on every query; merge needs the intent, not the state. |
| 4 | Merge replays actions rather than writing state | Validations and policies run against the real base at merge time. Slower and right. |
| 5 | Limit and offset applied after patching | The only way a branch-created row can appear in a limited query. Documented as the cost of correctness. |
| 6 | No Phoenix in core; AshPostgres optional | Keeps the dependency surface small for the first users. |
