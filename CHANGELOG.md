# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/) once it reaches 0.1.

## [Unreleased]

### Added

- **Rows whose primary key the database generates can be created in a branch.** A single `generated? true` integer or UUID key (`integer_primary_key`, `gen_random_uuid()`) gets a placeholder from a range no real key uses (integers from `-2_147_483_648` up, random UUIDs); the branch reads, updates and destroys the row under it, other rows refer to it by it, and the merge replays the create without forcing the key, learns the real one, and renames the placeholder in the input and keys of the later entries (text forms included). `Ramal.Merge.Result.keys` maps each placeholder to its real key, and `records` is keyed by the real key. `Ramal.Branch` gains `next_placeholder`, stored with the branch (`0` for a branch stored by 0.6). Other key types and composite keys are still refused with `:database_generated_key`. ADR 0039.
- **Upserts work inside a branch.** An upsert action (`upsert? true`, or `upsert?: true` given to `Ash.Changeset.for_create/4`) looks its row up by the upsert identity in the branch's view: a row of the base or one the branch created is updated (with the action's `upsert_fields`, or the attributes the call set, and the update defaults), and with none found the row is created. The merge replays the entry as an upsert with the identity and fields it had, so a row that appeared in the base meanwhile is updated rather than duplicated. An `upsert_condition` is still refused with `:upsert_unsupported`, and `upsert?: true` passed only to `Ash.create/2` at call time still acts as a create. ADR 0038.

### Changed

- `verification/`: a twelfth Bend law, `rename_shows_branch`, proves that renaming a placeholder key to the key the database gave the row leaves what the merge writes equal to what a read in the branch returned.

- Docs: `bench/README.md` and the README's benchmark figures come from a rerun of the full benchmark and `bench.memory` on 0.6.1, with the noise between two runs stated; the raw samples are in `bench/results/published/`.

### Fixed

- A read inside a branch runs the action's `authorize_results` checks (the runtime half of a policy) on the patched rows, so a row the branch created or changed is judged like any other and a row the branch destroyed is not. They ran on the database's rows before the patch. ADR 0037.

## [0.6.1] - 2026-10-23

Documentation only: the README, the design document and the other guides on Hex and HexDocs now describe 0.6. No code changes.

### Changed

- Docs: the README, design document, roadmap, verification README and security policy describe 0.6 (the verification is now a section of the README, the limits list matches what is left, and a branch in one tenant is documented). The ADR index lists every decision. `Ramal.Error` documents `:not_started`.

## [0.6.0] - 2026-10-23

A branch can work in one tenant, and Ramal has a formal model: a TLA+ model of the branch lifecycle checked with TLC and Bend 2 proofs of the overlay and merge rules, which found the three bugs fixed here. Read **Upgrading from 0.5** first.

### Upgrading from 0.5

1. **`ramal_live` needs `ramal ~> 0.6.0`**; the two packages share a version.
2. **A second process writing a row that a running action in the same branch already wrote gets `{:error, %Ramal.Error{reason: :row_busy}}`** until that action ends, and a merge or proposal waits up to 4 seconds for running actions (then `:timeout`). Code that writes one branch from several processes at once should retry on `:row_busy`.
3. **With the bundled storages, a storage outage now fails a merge before it commits** (`:storage`) instead of committing it and reporting `persist_failed`. A custom `Ramal.Storage` backend keeps the old behaviour until it implements the optional `mark_merged/2`.

### Added

- **A branch can work in one tenant**: `Ramal.branch(domain, tenant: tenant)`. Reads and writes of multitenant resources inside it must carry that tenant (`:tenant_mismatch` otherwise), the other tenants' rows never enter its overlay, the merge staleness check reads with the tenant, and a fork keeps it. A branch without a tenant still refuses multitenant resources used with one (`:multitenancy_unsupported`), now with a message that says to create it with `tenant:`. The internal check `ensure_untenanted/2` became `ensure_tenant/3`. Tested on Postgres with both strategies, attribute and schema-per-tenant (context), merge into the tenant's schema included. ADR 0034.
- `verification/`: a TLA+ model of the branch lifecycle (writes, reads, fork, propose, approve, merge, idle unload, kills and restarts), checked with TLC, and proofs in Bend 2 that a read in a branch sees what the merge's replay produces, that a merge keeps every edit made outside the branch to rows the branch did not touch, and that overlay entries stay honest about the base. A CI workflow runs both; `verification/README.md` says what is proven, what is assumed and what is not covered.
- `:row_busy`, a new `Ramal.Error` reason: a write to a row that another process's running action wrote in the same branch.
- `c:Ramal.Storage.mark_merged/2`, an optional storage callback, and `Ramal.Storage.already_merged/1`, the error it returns for a branch already stored as merged. Both bundled backends implement it (ADR 0035).

### Changed

- Docs: a branch checks only its own domain for resources that neither use `Ramal.Resource` nor opt out, but a resource of another domain that uses it is branched like the rest (read, written, diffed and merged); the open question about several domains per branch is closed with a test.

### Fixed

- **A branch whose merge committed can no longer be merged a second time** when the process running the merge dies before it finishes, or the node restarts before the merged branch is stored. The merge's transaction now stores the branch as merged and refuses one already stored so; with Postgres storage on the resources' repo, the merged row commits with the replay. A branch process whose merger died asks the storage before releasing the claim, and Postgres storage never stores a merged row back as open. A storage outage now fails the merge before it commits instead of reporting `persist_failed` after it (#143, ADR 0035).
- A merge, a proposal or a fork no longer takes a write of an action that is still running in another process. Before, if that action then failed, its undo was refused and the merge replayed (or the proposal showed, or the fork kept) a write whose action had failed. A merge and a proposal now wait for running actions (up to 4 seconds) and a fork leaves their writes out ([ADR 0033](docs/adr/0033-running-actions-hold-their-writes.md), #141).
- The writes of an action whose process dies before the action ends (a killed task, a crashed LiveView) are taken back, as a database rolls back a dead connection's transaction. Before, they stayed in the branch and were merged (#141).
- When an action failed after another process had written the same row in the branch, the undo dropped the other write from what reads saw but not from the log, so the merge wrote what the branch did not show. A second writer of a row is now refused with `:row_busy` until the first action ends (#141).
- A branch process killed by `max_heap_size` could be loaded again from storage, which is behind it, before its watcher marked it: writes its callers were told succeeded were lost, and a merge in progress could be claimed a second time. Such a branch is now refused with `:branch_too_large` at once (#142).

## [0.5.0] - 2026-10-23

Branch reads now agree with the branch in more places: pagination, aggregates (loaded, filtered and sorted), prepared queries and module calculations. Read **Upgrading from 0.4** first.

### Upgrading from 0.4

1. **`ramal_live` needs `ramal ~> 0.5.0`**; the two packages share a version.
2. **Reads that used to return the database's answer inside a branch now return the branch's**: a paginated read is cut from the patched list, an aggregate a read loads or filters or sorts on counts the branch's records, and a query prepared outside `Ramal.run/2` is patched when read inside it. Code that worked around the old answers (reading the page again, recomputing a count) can drop the workaround; tests that pinned the old numbers need the new ones.
3. **`distinct` on a calculation in a query that selects some attributes** now returns rows carrying every attribute.

### Added

- `examples/ash_ai`, a separate Mix project that CI runs against `ash_ai` 1.4.0: AshAi tools run in a branch through `AshAi.Tools.execute/4` and `AshAi.Mcp.Router`, end in a proposal, and the plug that takes the branch id from an MCP client checks the branch's owner. It also pins a finding: an AshAi `update` or `destroy` tool is a bulk action, which a branch refuses; `docs/agents.md` shows the generic action to use instead (#104).
- `Ramal.load/3` and `Ramal.load!/3`: `Ash.load/3` that follows the branch's foreign keys. Ash reselects the relationship's source attribute from the database without running any hook, so `Ash.load(herd, :paddock)` after the herd moved paddock in the branch followed the old one and Ash gives Ramal no way to intercept it. Inside a branch the new functions put the branch's attribute values on each record that has an overlay entry and load with `reuse_values?: true`; outside one they are `Ash.load/3`. ADR 0031.

### Changed

- Aggregates a read loads inside a branch (declared on the resource, or added with `Ash.Query.aggregate/4`) now see the branch: `count`, `exists`, `sum`, `min`, `max` and `avg` are computed from the related records the branch sees, for every row when the branch changed a resource on the aggregate's path. `[:ramal, :read, :unpatched_aggregate]` is emitted only for the aggregates this cannot do (`first`, `list`, `custom`, `uniq?`, a limit in the aggregate's query) ([ADR 0029](docs/adr/0029-declared-aggregates-in-branches.md), #102).

### Fixed

- **A filter or sort on an aggregate inside a branch now uses the branch's numbers** (it was judged on the base rows, so `filter herd_count >= 2` returned the paddocks the database counted two herds in and missed one the branch gave a third, and a paddock created in the branch had no number to sort by). A conjunct that names an aggregate over a resource the branch changed is evaluated in Elixir like a filter through a changed relationship, which reads the aggregate for every row the rest of the filter matches; the aggregates a filter or sort names are computed over the branch for the overlay's records. ADR 0032.
- **`distinct` on a calculation inside a branch now also works in a query that selects only some attributes.** It kept the data layer's distinct, which does not see the branch. The query is widened to every attribute, which evaluating the calculation in memory needs, so the rows carry attributes beyond the `select`. A distinct on an aggregate still keeps the data layer's.
- **A calculation with its own module and an `expression/2` is now evaluated on the rows a branch created or changed** (it came back `Ash.NotLoaded`, and a filter or sort on it judged the database's values). Calculations with only `calculate/3` already ran on the patched rows.
- **A paginated read inside a branch no longer repeats the branch's rows on every page or loses base rows** (#110, #101). `Ash.page!(page, :next)` returned the rows the branch created again on each page and never reached the base rows after the first page, and `Ash.stream!/2` in a batch job did the same. When the branch changed the resource, the page is now cut from the whole patched list: a row created in the branch is on the page its sort position puts it, a deleted row shortens nothing, `count` is the patched count, and `after`/`before` keyset cursors walk the patched list without gaps or repeats. A page costs the read of every row the filter matches; a resource the branch did not change is still paged by the database, and so is a paged relationship load ([ADR 0030](docs/adr/0030-pages-cut-from-the-patched-list.md)).
- **A query prepared outside `Ramal.run/2` and read inside it is now patched with the branch** (it read base data before). The preparation adds a `before_transaction` hook to every query; it installs the read hooks only when a branch is current when the query runs, so an atomic bulk update of a prepared query outside a branch still runs in the database. ADR 0028.
- An aggregate declared on a resource no longer comes back as `Ash.NotLoaded` on a row the branch created or changed (#115).

## [0.4.3] - 2026-10-23

The fixes from the external review of 0.4.2, four of them critical: a branch write reaching Postgres. Read **Upgrading from 0.4.2** first.

### Upgrading from 0.4.2

1. **`Ramal.branch/2` can now return `:unbranchable_resources`.** Every resource of the domain that has a create, update or destroy action must use `Ramal.Resource` or opt out with `ramal do branchable? false end` (a resource that opts out is written for real, from a branch too).
2. **Build a changeset and run it in the same place.** One built outside `Ramal.run/2` and submitted inside, or the reverse, now fails with `:branch_mismatch`. Prepare queries inside `run/2` too.
3. **Tasks started inside `Ramal.run/2` with `Task` are in the branch**, so `Ramal.current/0` returns it there. `ramal_live` needs `ramal ~> 0.4.3`.

### Added

- `Ramal.Change.redact/1` returns a change with the values of `sensitive?` attributes replaced by `"[redacted]"`.

### Security

- `ramal_branch_diff` of `Ramal.Tools` no longer sends the values of `sensitive?` attributes to the model: they are returned as `[redacted]`, as the inspector shows them (#118).
- `ramal_discard_branch` refuses a `:proposed` branch, so an agent cannot withdraw a proposal a person is reviewing (#118).
- `SECURITY.md` has a section on the tools, and the `docs/agents.md` examples check the branch's owner before running in a branch the model or an MCP client named (#118).
- The Release workflow publishes only from `main` and only for a commit whose CI run succeeded (it now starts from a successful CI run, or from a manual run on `main`), reads the Hex key from the `hex` environment in the two publish steps only, and pins its actions to commit SHAs. `CONTRIBUTING.md` says how to set the environment up; `SECURITY.md` names GitHub private vulnerability reporting as a channel (#119).

### Fixed

- `Ramal.merge/2` and `Ramal.approve/2` no longer return an error for a merge that committed when the storage refuses the `:merged` write. Before, the rows were in the database while the caller was told the merge failed, the branch stayed open and a second merge failed as `:stale` or on duplicate keys. Now the result is `{:ok, result}` with the storage error in the new `persist_failed` field of `Ramal.Merge.Result`; the branch is merged in its process, which refuses a second merge, emits `[:ramal, :branch, :persist_failed]` with `reason: :merged` and writes the branch again at its idle timeout ([ADR 0023](docs/adr/0023-merge-commit-is-final.md)).
- Calls to a branch process have explicit timeouts: 5 seconds for reads and writes and 60 for the calls that persist the whole branch (merge, propose, reject, discard). A timeout is `{:error, %Ramal.Error{reason: :timeout}}`, a new reason, and a captured write that timed out is taken back instead of being applied late.
- `Ramal.fork/2` is refused with `:not_open` while a merge holds the branch. Before, a fork of a log that was about to be replayed could be merged again and write the same rows twice.
- A calculation that a read action loads in its own `prepare` is now evaluated on the rows the branch created or changed; before, those rows came back `NotLoaded` for it (#116).
- `Ramal.aggregate/4` now sees a branch carried only by `context: Ramal.context(branch)`, in the options or in the query's context, as reads do; before, it answered with the base's numbers (#114).
- An update or destroy through a record read with `Ash.Query.select/2` no longer stores a partial row in the branch or skips its staleness check: the full row is read inside the branch first, and the write is refused with `:partial_record` if that fails (#113).
- A create that manages a `belongs_to` now stores the new row's foreign key in the branch: the record the action returns, later reads and the diff showed `nil` until merge (#112).
- A limit is now documented: a text sort inside a branch uses byte order, not the database's collation, once the branch has changed the resource, so mixed-case text can sort differently than outside it; `Ramal.aggregate/4` `:min` and `:max` on strings have the same gap. Ramal does not guess a collation ([ADR 0024](docs/adr/0024-text-sort-order.md), #117).
- A filter or sort through a relationship whose resource the branch changed (`paddock.name == "L07"` after the branch renamed the paddock) is now evaluated against the branch's rows, in reads and in `Ramal.aggregate/4`; before, the database's join used the base's rows and the herds kept matching the old name. The part of the filter that reaches the changed resource is checked in memory, so such a read fetches more rows ([ADR 0025](docs/adr/0025-relationship-filters-in-elixir.md), #111).
- **A changeset built outside `Ramal.run/2` and run inside it no longer writes to the database** (#105). The branch is checked again when the action runs: a changeset built outside and run inside, built inside and run after, or built under one branch and run under another, fails with `:branch_mismatch`. A query prepared outside a branch and read inside it is still not patched (documented; prepare queries inside `run/2`). ADR 0026.
- **`Ash.bulk_create` with `max_concurrency` inside a branch is refused (`:bulk_unsupported`) instead of writing to the database** (#106), and **a write from a `Task` started inside `Ramal.run/2` is captured** (#120). Tasks started through `Task` (and the ones Ash starts) are now in the branch of the process that started them, so `Ramal.current/0` returns it there; `Ramal.run/2` inside a task still works. A captured write from a task started by a hook of another captured action is refused (`:task_in_action`).
- **`Ramal.branch/2` refuses a domain with a resource that has write actions and neither uses `Ramal.Resource` nor opts out with `branchable? false`** (`:unbranchable_resources`, #107). A write to such a resource used to reach the database from inside a branch with no error. Add the extension, or opt out and accept that its writes are real. ADR 0027.

## [0.4.2] - 2026-10-23

Docs only: now that the repository is public, the README images and the Livebook badge link GitHub (`raw.githubusercontent.com`) again, so they render on Hex.pm, HexDocs and GitHub, and the badge opens the notebook. No code change; `~> 0.4.0` pins keep working.

## [0.4.1] - 2026-10-23

Docs only: the README images and the Livebook badge now work on Hex.pm and HexDocs. No code change; `~> 0.4.0` pins keep working.

### Fixed

- The README logo and screenshots render on Hex.pm and HexDocs, and the "Run in Livebook" badge opens the notebook, without the repository being public: the images and `demo/ramal_tour.livemd` are published with the docs and the READMEs link their HexDocs URLs.

## [0.4.0] - 2026-10-23

Faster fork, diff and reads of a large branch, a third of the memory and storage, an indexed `owner` column, and fixes to calculations and the read prefilter. One migration and one deploy caveat; read **Upgrading from 0.3.0** first.

### Upgrading from 0.3.0

1. **Add the owner column** (Postgres 12 or later). Run `mix ramal.gen.migration`; it writes only the migration that is missing (`add_ramal_branch_owner` for a table made by 0.3.0), then run `mix ecto.migrate`. The column is generated by Postgres from `state`, so there is nothing to backfill, but the table is rewritten once, so run it in a quiet moment on a large table. Until it runs, everything works except `Ramal.list/2` with `owner:`, whose error tells you to run the task.
2. **Deploy every node that shares the `ramal_branches` table before any of them writes** ([ADR 0022](docs/adr/0022-compact-state.md)). 0.4.0 stores branches in state version 2 and still reads version 1, but 0.3.0 cannot read version 2. In a rolling deploy, a 0.4.0 node that writes a branch makes that branch unreadable by the 0.3.0 nodes still running. Stop the 0.3.0 nodes first (or drain writes to branches during the deploy) and do not roll back to 0.3.0 once 0.4.0 has written, unless you accept losing those branches.
3. Nothing else changes in the public API. `Ramal.list/2`'s `owner:` may miss a version 1 branch whose owner is a struct or a date until the branch is written again; ids and strings, the usual owners, are unaffected.

### Added

- `demo/`, a guided walkthrough you run locally with `elixir demo/walkthrough.exs` against a Postgres from `demo/docker-compose.yml`, and the same tour as a Livebook notebook, `demo/ramal_tour.livemd`, with a "Run in Livebook" badge in the READMEs. Both step through branching, real-action validation and policies, diff, fork, exact aggregates, merge, a stale refusal, an all-or-nothing replay failure, and a proposal approved by a person. Not part of the Hex package.

### Fixed

- The read prefilter, Ramal.Prefilter (0.3.0), could rule out a record that a read in a branch should have returned. It treated an `and` with one `false` side as `false` whatever the other side was, but Ash's filter runtime is not three-valued: `nil and false` is `nil`, `nil or false` is `false` and `not nil` is `nil`. So under a `not`, a filter such as `not (not (name in [""] and head == 1) or ...)` was ruled out for a record with a `nil` attribute that the runtime accepts. An expression now evaluates to the set of values the runtime can give it, and the record is ruled out only when `true` is not among them. Found by a property test that failed about one run in six.
- `ramal_live`: a UUID in a diff (the row key and the before and after cells) no longer wraps in the middle of a group in the narrow column. It keeps to one line, cut short with an ellipsis, and the whole id is the tooltip.
- `distinct` on a calculation inside a branch is applied over the branch's view, as 0.3.0 did for attributes: the base query is read without it and the patched rows are made distinct in memory with `Ash.Query.apply_to/3`, so a row the branch changed counts under its new value, a row it created gets its group, and a destroyed row no longer stands for one. A query that selects only some attributes, or a distinct on an aggregate, keeps the data layer's distinct and does not see the branch.
- Loading an expression calculation inside a branch (`Ash.Query.load(:size)`, `load:` on a read, `Ash.get/3`) returned `Ash.NotLoaded` for rows the branch created or changed, because the data layer computes it on the base row. Those rows now get the calculation evaluated in memory with their branch values. A filter on an expression calculation had the related fault: `Ash.Filter.Runtime` loaded it through the data layer, so a row the branch changed was judged by its database value and could stay in, or be left out of, a result it did not belong in. Sorting by one is covered too. A calculation with its own module is not evaluated over the branch.

### Changed

- A read in a branch with a large overlay no longer scans the whole overlay for the resource it reads. From 5,000 entries on, once two reads in a row have found the overlay unchanged, the branch process groups it by resource and answers `overlay?`, `keys`, `slice` and `select` from that group, so a read of a resource the branch barely touched costs the same whatever else the branch holds (10,000 entries in another resource: about 1.0 ms to 0.65 ms). A write drops the grouping, so a branch that alternates writes and reads keeps scanning, as before.
- `Ramal.fork/2` copies the branch once less: the new process is started empty and receives the fork in one message, instead of the fork travelling through the dynamic supervisor (copied into it, then into the process). A fork of a branch with 1,000 changes took about 2.7 ms instead of 4.8.
- `Ramal.diff/1` is about a third faster for a branch with many changes: it no longer builds and deduplicates a list of attribute names for every updated row, and `Ramal.Resource.attributes/1` makes one pass over the attribute names. Same changes, same order.
- `Ramal.diff/1` runs inside the branch process, so only the changes cross the process boundary and not the whole branch (overlay, log and base). The diff of a branch with 1,000 changes took about 2.8 ms instead of 5.4. The process is busy for the length of the diff, as it is for any other call.
- `Ramal.Storage.Postgres` filters `Ramal.list/2`'s `owner:` on a real `owner` column with an index instead of on `state -> 'owner'` ([ADR 0021](docs/adr/0021-owner-column.md)). The column is generated by Postgres from `state` (Postgres 12 or later), so there is nothing to backfill, a branch stored by 0.2 or 0.3 is covered, and an old node writing the table during a deploy cannot put it out of step; the index is a partial hash index because the owner is any term. `mix ramal.gen.migration` now writes the migrations that are missing: a new install gets `create_ramal_branches` and `add_ramal_branch_owner`, and a host from 0.3.0 gets only the second. Run it, then `mix ecto.migrate` (the table is rewritten once). Until then everything works but the `owner:` filter, whose error says to run the task.
- `demo/walkthrough.exs` installs `ramal ~> 0.3.0` from Hex, and falls back to the checkout it runs from while that version is not published.
- `ramal_live/examples/farm_demo.exs` finds Postgres on port 5436 (the `demo/` compose file) or 5435 by itself, and prints one line and exits when none answers instead of a Postgrex stack trace.
- A branch holds 24 to 39 percent fewer words on its process heap, and a branch loaded from storage 41 to 55 percent fewer. The branch process points the terms that are equal at one copy: the fields of an update's record that the update did not change point at the snapshot of the row, the fields a row shares with the write before it (foreign keys, states, metadata) point at that write, the row's key is the one term of its ref, a struct's key tuple is the module's literal, and a log entry shares its actor with the entry before it. A message and an ETS table copy a term in full, so a branch used to cost its flat size once written and again every time it was loaded. `Ramal.Branch.share/1` does the same for a branch that comes out of storage and runs when its process starts. Nothing changes in what a branch holds, only in how much memory holds it; `mix bench.memory` in `bench/` prints the numbers.
- `Ramal.Storage.Postgres` stores a branch in about a third of the JSON (state version 2): the common date structs (`DateTime` in UTC, `NaiveDateTime`, `Date`, `Time`) are ISO 8601 text, a struct lists only the fields that differ from its module's default, the parts of a record that many records have in common (`__meta__`, `__metadata__`) are written once, and a base row's snapshot is stored as what differs from the branch's record of the same row. A branch of 1,000 updated rows and 200 created ones goes from 3,018,251 to 1,023,133 bytes (`mix bench.memory`). A branch stored by 0.3.0 or earlier is still read; one written by this version is not read by 0.3.0, so upgrade every node that shares the table before the first of them writes.
- `Ramal.merge/2` (and `Ramal.approve/2`) holds one copy of the branch in the calling process instead of two: it fetched the whole branch only to read its domain for the telemetry event, and kept that copy until the merge ended. The caller's heap during a merge of 1,000 updated rows goes from 2,639,025 to 1,517,744 words (`mix bench.memory`).

## [0.3.0] - 2026-10-23

### Added

- `Ramal.in_branch?/1` tells a notifier (or a changeset, query or context map) that a write was made with `context: Ramal.context(branch)`. Those writes send their notifications, unlike writes inside `Ramal.run/2`, and Ash has no per-call switch to hold them back, so the notifier skips them itself.
- Tooling for AI agents ([ADR 0019](docs/adr/0019-agent-tools.md), [guide](docs/agents.md)). `Ramal.Tools` offers the branch calls as tools for any LLM tool loop or MCP server: `definitions/1` (name, description, JSON Schema) and `call/3` for `ramal_open_branch`, `ramal_list_branches`, `ramal_fork_branch`, `ramal_branch_diff`, `ramal_propose_branch` and `ramal_discard_branch`. There is no merge, approve or reject tool: an agent proposes and a person decides. The host fixes `:domain`, `:owner` and `:proposed_by`, and a branch outside them is reported as not found. `Ramal.context/1` returns the `context:` that runs an Ash call in a branch, for tool servers that cannot use `Ramal.run/2` (it does not hold back notifications). `usage-rules.md` and a skill in `usage-rules/skills/ramal/` teach coding agents to use Ramal, in the format of the `usage_rules` package. No new dependency.
- An optional owner on a branch: `Ramal.branch/2` and `Ramal.fork/2` take `owner:` (a fork keeps its parent's), `Ramal.list/2` takes `owner:` to list one owner's branches (`owner: nil` lists the unowned), and `ramal_inspector` takes an `:owner` `{module, function}` that scopes the page to the signed-in actor's branches. All are off by default and a branch stored by 0.2.0 loads as unowned. The owner is stored in the branch state (no migration) and filtered in SQL by `Ramal.Storage.Postgres`. It filters; it does not authorize ([ADR 0018](docs/adr/0018-branch-owner.md), `SECURITY.md`).

### Documented limits

- `Ash.load` onto a record the branch changed follows the database's foreign key, not the branch's, because Ash reselects the relationship's source attribute without running the read hooks. `reuse_values?: true` and loading inside a read (`Ash.Query.load/2`) see the branch. Ash 3.37 offers no hook for the reselect, so this is pinned by a test and written in `Ramal.Preparation` and DESIGN rather than fixed.

### Fixed

- `distinct` on attributes inside a branch gave the database's groups: a group whose database pick the branch had destroyed or changed vanished or kept the old row, and a row the branch created came back as a second row of its group. The patch now keeps the first row of each group in the order of `distinct_sort` (or `sort`) over the branch's view. A distinct on a calculation or aggregate keeps the data layer's.
- An idle branch whose storage write fails no longer unloads and loses its overlay and log. It stays loaded and tries again at the next idle timeout. Before, `terminate/2` ignored the error and announced an unload; now the failure is the new event `[:ramal, :branch, :persist_failed]`, also emitted when a shutdown cannot persist.
- An update through a struct older than the branch's copy of the row keeps the earlier changes. Updating a record twice (`Ash.update!(herd, %{head: 31})`, then `Ash.update!(herd, %{name: "x"})` on the same struct) put the stale struct back with only the second change, so reads and `Ramal.diff/1` lost the first one while `Ramal.merge/2` applied both. The changes now go onto the row the branch holds, which is what two UPDATE statements do.
- `Ramal.Tools` no longer builds its status map with `String.to_existing_atom/1` at compile time. It needed another module of the same compile to have created the atoms already, and an incremental `mix compile` (and so `mix docs`) failed with "not an already existing atom".
- Updating or destroying a row the branch had already destroyed is refused with Ash's `StaleRecord`, as AshPostgres refuses it on the real table. Before, an update brought the row back and a second destroy was logged, and `Ramal.merge/2` then failed replaying them against a row that was not there.
- `Ramal.merge/2` and `Ramal.aggregate/4` work on a resource whose read action requires pagination (`pagination required?: true`) or has a default limit. The staleness check of a merge raised `Protocol.UndefinedError` on the page it got back, and `Ramal.aggregate/4` raised `ArgumentError`; both now read every matching row whatever the action's pagination.
- An `atomic_update` (the change, or `Ash.Changeset.atomic_update/3`) inside a branch is applied to the row the branch holds. It was dropped, so a read, the action's result and `Ramal.diff/1` showed the row unchanged while `Ramal.merge/2` replayed the update and incremented it. An expression that needs the database fails the action with the new reason `:atomic_unsupported` instead of being dropped.
- A many_to_many load inside a branch sees the links the branch created or destroyed, so `manage_relationship` with `type: :remove` finds a link the branch created and `type: :append` no longer links a vet twice. `type: :append_and_remove` with a link to remove is still refused as a bulk action ([ADR 0017](docs/adr/0017-many-to-many-links-in-a-branch.md)).

### Changed

- `Ramal.run/2` asks the branch process for its status instead of fetching the whole branch, so a run no longer copies the overlay, log and base to the caller. It cost 1.6 ms at 1,000 overlay rows on every call, and a get-and-update in a branch with that overlay is 1.9 times faster (`bench/`, same run setup).
- A read inside a branch costs what it returns, not the size of the overlay ([ADR 0020](docs/adr/0020-read-selects-overlay.md)). The branch process hands the read only the overlay entries of the rows the database returned and the records that may satisfy the filter, and the new Ramal.Prefilter rules the others out with plain comparisons before `Ash.Filter.Runtime` looks at them (it never rules out a record the filter accepts; a filter it does not understand takes the old path). With 1,000 overlaid rows a read of 1% of the table goes from 6.4 ms to 2.4 ms and a get-and-update from 3.7 ms to 1.5 ms (`bench/`, same run setup); the results of reads are unchanged.
- Fingerprinting a read is about twice as fast. A read looks up the attribute names and the primary key once for all its rows instead of once per row, collects the attribute values in one pass, and sends the branch process a list instead of building a map. The hash is the same, so a fingerprint stored by an earlier version still compares equal. `Ramal.Resource.fingerprint/1` of 20,000 rows goes from 34 ms to 19 to 23 ms, and a wide read (2,000 rows) in an empty branch from 15.8 to 10.5 ms, against 8.9 ms for the same read with no branch (`bench/`, same run setup).
- `Ramal.merge/2` is about three times faster. Each replayed update or destroy read its row again with `Ash.get/3`, which cost more than the update itself; it now takes the row from the staleness check, which read and locked it a moment before in the same transaction. A row is used once, and the reuse stops at the first log entry a hook wrote (`nested?`), where the hook may have changed any row. Merging 100 updates goes from 92 ms to 33 ms and 1,000 updates from 880 ms to 270 ms (`bench/`, same run setup, two runs back to back).
- `Ramal.aggregate/4` asks the branch process for the primary keys of the overlay and no longer copies every overlay record just to take the keys of them.
- `Ramal.Storage.Codec.encode_state/1` is about 20% faster. It printed the module name of the resource for the path of every value it wrote, to name the value in an error that almost never happens; the path is now printed only when an error needs it. Encoding a branch with 1,000 changes goes from about 25 ms to 20 ms.
- The READMEs of `ramal` and `ramal_live` are rewritten for a newcomer: what Ramal does, why, what to build with it, a quickstart, the limits, and what the inspector shows. All links and images are absolute so Hex renders them.
- The READMEs show a screenshot of the inspector running the farm demo, and the `ramal_live` README an animation of the columns filling in (`assets/inspector.png`, `assets/inspector.gif`), instead of saying there is none.
- The install snippets in the READMEs and the `RamalLive` module doc point at Hex (`{:ramal, "~> 0.2.0"}`, `{:ramal_live, "~> 0.2.0"}`), with Hex and HexDocs badges.

## [0.2.0] - 2026-10-23

Proposals, fast aggregates, many-to-many join resources, the `ramal_live` inspector, a benchmark, and a security pass. No breaking change to the public API of 0.1.0: a branch stored by 0.1.0 loads unchanged, and the public functions of 0.1.0 behave as before.

### Added

- `Ramal.propose/2`, `Ramal.approve/2` and `Ramal.reject/2`: a branch can be frozen as a proposal (status `:proposed`) that a decider approves, which merges it, or rejects. The proposer, the decider, the reasons, the replay count and the stale rows are recorded on the branch and stored with it; `list(domain, status: :proposed)` finds the pending ones. Telemetry `[:ramal, :branch, :propose | :approve | :reject]`. Branches stored by 0.1.0 load unchanged.
- `Ramal.aggregate/4` and `Ramal.aggregate!/4`: count, exists, sum, min, max and avg over the rows a read returns inside a branch, so a branch's creates, updates and destroys are included. Outside a branch they call the matching `Ash` function. `Ramal.Aggregate` holds the pure computation. The database aggregates the rows the overlay does not touch and the branch reads only the overlaid ones, so the cost follows the overlay and not the table; a query with a limit, an offset or a distinct reads every matching row. The rows the database aggregates are not fingerprinted for the merge staleness check (ADR 0013).
- Many-to-many join resources inside a branch are tested and documented (DESIGN section 4.1 point 7, ADR 0014): the join resource gets overlay entries keyed by its primary key, and a branch diffs, merges and stores them. A many_to_many load and `manage_relationship` do not see links the branch changed; both are listed as known limits.
- `ramal_live/`: a separate Mix project with a LiveView inspector for branches. `ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub` mounts it inside the host's own `live_session`, so it uses the host's LiveView socket and JavaScript; there is no asset pipeline, the CSS is inline and has light and dark themes. Open and proposed branches are columns with their `Ramal.diff/1` as before and after rows, and buttons to fork, merge, discard, approve and reject, each destructive one with an inline confirmation. `RamalLive.Broadcaster` turns Ramal's telemetry into PubSub messages so the columns update live. Core is unchanged. Decision in ADR 0015.
- `ramal_live/examples/farm_demo.exs`: a runnable demo of the inspector for a screen recording. One command starts a Phoenix Playground app on a seeded farm in the `ramal_dev` database; "Explore 4 alternatives" opens four branches that each move a herd to a different paddock while the columns fill in live, and merging one makes the others stale. How to run it is in `ramal_live/README.md`.
- `bench/`: a separate Mix project that measures fork, read, write, merge, fingerprinting and a tree search against two plain-Postgres baselines (a table copied per fork, and a shared delta table). `mix bench` runs it, `mix bench --quick` is a smoke run that CI compiles and executes. Results and their limits are in `bench/README.md`.
- `bench/` results rerun after fast aggregates: the tree search takes 183 ms instead of 5,705 ms (1.07 times the delta baseline instead of 23 times), and every table in `bench/README.md` now comes from that one run. The earlier raw samples stay in `bench/results/published/` next to the new ones.
- `ramal_live` is versioned with Ramal (0.2.0) and builds as a Hex package: `RAMAL_LIVE_HEX=1` makes its `mix.exs` depend on the published `ramal ~> 0.2.0` instead of the checkout next to it, and the package ships its `LICENSE` and builds its docs with ExDoc.
- Community files for the public launch: `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), `SECURITY.md`, bug and feature issue templates, a pull request template that mirrors the rules in `CLAUDE.md`, and Dependabot for the root Mix project, `bench/` and GitHub Actions.
- A "Security model and defaults" section in `SECURITY.md`, and ADR 0016: what Ramal enforces and what it leaves to the host, how stored state is treated, and how to mount the inspector in production. CI runs `mix hex.audit` for the library, `bench/` and `ramal_live/`.
- `Ramal.Supervisor` options `:max_active_branches` and `:branch_rate`: optional per-domain limits on the open and proposed branches, and on the branches and forks created per window. `Ramal.branch/2` and `Ramal.fork/2` return `{:error, %Ramal.Error{reason: :limit_reached}}` past either, with the limit in `details`, and emit `[:ramal, :limit, :reached]`. Both are off by default, so nothing changes until a host sets them (ADR 0016, `SECURITY.md`).
- `c:Ramal.Storage.count/3`, an optional callback that counts a domain's branches by status without loading them. `Ramal.Storage.ETS` and `Ramal.Storage.Postgres` define it; a backend without it is counted with `list/3`.

### Security

- `ramal_live`: the `:actor` option of `ramal_inspector/2` is required. A router without it fails to compile with a message that says what to pass, and a route whose actor function does not exist raises when the page opens. A page with no actor would merge every branch as the actors the writes were captured with and record no decider; a tool with no users passes a function that returns a constant (ADR 0016).
- `ramal_live`: attributes marked `sensitive?: true` show as `[redacted]` in a branch's diff. The page printed every value, so a password hash or token written in a branch was visible to everyone who could open the inspector.
- `ramal_live`: when the `:actor` function returns `nil` the page refuses fork, merge, discard, approve and reject. Before, a session without a user merged as the recorded actors with no decider.
- `inspect/1` of a `Ramal.Branch` prints only its id, name, domain, status and creation time. The log holds the raw input of every captured write, which Ash does not redact, and a crash report prints the state of a branch process.
- `Ramal.Storage.Codec.decode_state/2` returns `{:error, %Ramal.Error{reason: :storage}}` for a malformed stored state instead of raising, never echoes stored values in the error, rejects a module name that is not a name (`Elixir.../../x`) before it touches the code path, and rejects a stored struct whose module is not a struct.

### Fixed

- `Ramal.merge/2` and `Ramal.approve/2` on resources backed by `Ash.DataLayer.Ets` returned a `CaseClauseError` instead of `{:error, %Ramal.Error{}}` when the staleness check or the replay failed. The error is now returned as with Postgres. ETS cannot roll back, so rows replayed before a failing entry stay written; the error message and `details.not_rolled_back` say so (ADR 0007).
- `docs/ROADMAP.md` and `bench/README.md` no longer say the DAPLab article was unreachable; they link it and state how the benchmark differs from theirs.
- An update that changes no attribute is now logged, so a merge replays it. Before, the rows its hooks or managed relationships wrote (the links of a `manage_relationship`, a record created in an `after_action`) were logged as nested under an update that was not logged, and the merge dropped them.
- A load of a many_to_many (or a limited has_many) inside a branch no longer loses a destination row the branch updated: the patched row keeps the source record Ash groups the load by.
- README: the DAPLab quotation now matches the article word for word, and the Neon and Dolt summary matches its findings.

## [0.1.0] - 2026-10-22

### Added

- Project scaffold: design document, roadmap, conventions, CI, test database setup, logo.
- `Ramal.Overlay`: the pure overlay of a branch (put, slice, patch, diff, merge for forks), `Ramal.Change` and `Ramal.Error`.
- Branch processes: `Ramal.Supervisor`, `Ramal.branch/2`, `run/2`, `run!/2`, `current/0`, `get/1`, `list/2` and `discard/1`, with idle unload, transparent rehydration, a heap limit, and telemetry for the branch lifecycle.
- `Ramal.Storage` behaviour and the `Ramal.Storage.ETS` backend.
- `Ramal.Resource` extension and `Ramal.Preparation`: reads inside a branch see rows created, updated and deleted in it, with limit, offset, sort, select and relationship loads applied to the patched rows. Telemetry for `[:ramal, :read, :patch]` and `[:ramal, :read, :unpatched_aggregate]`.
- `Ramal.Capture`: creates, updates and destroys inside `Ramal.run/2` land in the branch overlay and log instead of the data layer, with validations, policies and hooks still running. Notifications are dropped unless a resource sets `notify_in_branch? true`; bulk actions and upsert actions are refused; a failed action undoes its writes. `Ramal.Error` is now a Splode error with `Ramal.Error.find/1`. Telemetry for `[:ramal, :write, :capture]`.
- `Ramal.fork/2` and `Ramal.diff/1`: a fork starts with its parent's overlay, log and base and shares nothing afterwards; `diff/1` returns `Ramal.Change` structs in log order without querying the database. Reads record a fingerprint of every base row they return, for the merge staleness check.
- `Ramal.branch/2` returns `:no_branchable_resources` for a domain none of whose resources opted in.
- `Ramal.merge/2`: checks that the base rows the branch saw are unchanged (`on_stale: :error | :ignore | fun`), then replays the branch log through the real actions in one transaction, so validations and policies run again. Failures return `:stale` or `:merge_failed` and leave the base untouched; a merged branch cannot be merged again. Telemetry span `[:ramal, :merge]`.
- `Ramal.Storage.Postgres` and `mix ramal.gen.migration`: branches persist in a `ramal_branches` table and load back equal in a fresh VM. `Ramal.Storage.Codec` serializes a branch through the Ash embedded types without creating atoms. `c:Ramal.Storage.list/3` now returns `{:ok, branches} | {:error, error}`.
- Documentation pass for 0.1: the README example runs as a test (`test/readme_test.exs`), a test checks that every public module has an example and every public function a `@doc` and `@spec`, `mix docs` builds without warnings and includes the ADRs, and every **[confirm]** mark in the design is resolved.
- A multitenant resource used with a tenant inside a branch is refused with `:multitenancy_unsupported` (the `ensure_untenanted/2` check), instead of mixing tenants in one overlay or failing at merge.
- Stored branches no longer hold the `sensitive?` attributes of an actor that is an Ash record (they are stored as `nil`); other actors are stored as before.

[Unreleased]: https://github.com/agustinrojas1/ramal/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/agustinrojas1/ramal/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/agustinrojas1/ramal/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/agustinrojas1/ramal/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/agustinrojas1/ramal/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/agustinrojas1/ramal/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/agustinrojas1/ramal/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/agustinrojas1/ramal/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/agustinrojas1/ramal/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/agustinrojas1/ramal/releases/tag/v0.1.0
