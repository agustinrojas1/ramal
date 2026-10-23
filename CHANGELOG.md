# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/) once it reaches 0.1.

## [Unreleased]

### Added

- `Ramal.in_branch?/1` tells a notifier (or a changeset, query or context map) that a write was made with `context: Ramal.context(branch)`. Those writes send their notifications, unlike writes inside `Ramal.run/2`, and Ash has no per-call switch to hold them back, so the notifier skips them itself.
- Tooling for AI agents ([ADR 0019](docs/adr/0019-agent-tools.md), [guide](docs/agents.md)). `Ramal.Tools` offers the branch calls as tools for any LLM tool loop or MCP server: `definitions/1` (name, description, JSON Schema) and `call/3` for `ramal_open_branch`, `ramal_list_branches`, `ramal_fork_branch`, `ramal_branch_diff`, `ramal_propose_branch` and `ramal_discard_branch`. There is no merge, approve or reject tool: an agent proposes and a person decides. The host fixes `:domain`, `:owner` and `:proposed_by`, and a branch outside them is reported as not found. `Ramal.context/1` returns the `context:` that runs an Ash call in a branch, for tool servers that cannot use `Ramal.run/2` (it does not hold back notifications). `usage-rules.md` and a skill in `usage-rules/skills/ramal/` teach coding agents to use Ramal, in the format of the `usage_rules` package. No new dependency.
- An optional owner on a branch: `Ramal.branch/2` and `Ramal.fork/2` take `owner:` (a fork keeps its parent's), `Ramal.list/2` takes `owner:` to list one owner's branches (`owner: nil` lists the unowned), and `ramal_inspector` takes an `:owner` `{module, function}` that scopes the page to the signed-in actor's branches. All are off by default and a branch stored by 0.2.0 loads as unowned. The owner is stored in the branch state (no migration) and filtered in SQL by `Ramal.Storage.Postgres`. It filters; it does not authorize ([ADR 0018](docs/adr/0018-branch-owner.md), `SECURITY.md`).

### Fixed

- An update through a struct older than the branch's copy of the row keeps the earlier changes. Updating a record twice (`Ash.update!(herd, %{head: 31})`, then `Ash.update!(herd, %{name: "x"})` on the same struct) put the stale struct back with only the second change, so reads and `Ramal.diff/1` lost the first one while `Ramal.merge/2` applied both. The changes now go onto the row the branch holds, which is what two UPDATE statements do.
- `Ramal.Tools` no longer builds its status map with `String.to_existing_atom/1` at compile time. It needed another module of the same compile to have created the atoms already, and an incremental `mix compile` (and so `mix docs`) failed with "not an already existing atom".
- Updating or destroying a row the branch had already destroyed is refused with Ash's `StaleRecord`, as AshPostgres refuses it on the real table. Before, an update brought the row back and a second destroy was logged, and `Ramal.merge/2` then failed replaying them against a row that was not there.
- `Ramal.merge/2` and `Ramal.aggregate/4` work on a resource whose read action requires pagination (`pagination required?: true`) or has a default limit. The staleness check of a merge raised `Protocol.UndefinedError` on the page it got back, and `Ramal.aggregate/4` raised `ArgumentError`; both now read every matching row whatever the action's pagination.
- An `atomic_update` (the change, or `Ash.Changeset.atomic_update/3`) inside a branch is applied to the row the branch holds. It was dropped, so a read, the action's result and `Ramal.diff/1` showed the row unchanged while `Ramal.merge/2` replayed the update and incremented it. An expression that needs the database fails the action with the new reason `:atomic_unsupported` instead of being dropped.
- A many_to_many load inside a branch sees the links the branch created or destroyed, so `manage_relationship` with `type: :remove` finds a link the branch created and `type: :append` no longer links a vet twice. `type: :append_and_remove` with a link to remove is still refused as a bulk action ([ADR 0017](docs/adr/0017-many-to-many-links-in-a-branch.md)).

### Changed

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
- A multitenant resource used with a tenant inside a branch is refused with `:multitenancy_unsupported` (`Ramal.Resource.ensure_untenanted/2`), instead of mixing tenants in one overlay or failing at merge.
- Stored branches no longer hold the `sensitive?` attributes of an actor that is an Ash record (they are stored as `nil`); other actors are stored as before.

[Unreleased]: https://github.com/agustinrojas1/ramal/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/agustinrojas1/ramal/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/agustinrojas1/ramal/releases/tag/v0.1.0
