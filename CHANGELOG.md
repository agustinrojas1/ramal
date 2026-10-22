# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/) once it reaches 0.1.

## [Unreleased]

### Added

- Many-to-many join resources inside a branch are tested and documented (DESIGN section 4.1 point 7, ADR 0013): the join resource gets overlay entries keyed by its primary key, and a branch diffs, merges and stores them. A many_to_many load and `manage_relationship` do not see links the branch changed; both are listed as known limits.
- `bench/`: a separate Mix project that measures fork, read, write, merge, fingerprinting and a tree search against two plain-Postgres baselines (a table copied per fork, and a shared delta table). `mix bench` runs it, `mix bench --quick` is a smoke run that CI compiles and executes. Results and their limits are in `bench/README.md`.
- `Ramal.propose/2`, `Ramal.approve/2` and `Ramal.reject/2`: a branch can be frozen as a proposal (status `:proposed`) that a decider approves, which merges it, or rejects. The proposer, the decider, the reasons, the replay count and the stale rows are recorded on the branch and stored with it; `list(domain, status: :proposed)` finds the pending ones. Telemetry `[:ramal, :branch, :propose | :approve | :reject]`. Branches stored by 0.1.0 load unchanged.
- `Ramal.aggregate/4` and `Ramal.aggregate!/4`: count, exists, sum, min, max and avg over the rows a read returns inside a branch, so a branch's creates, updates and destroys are included. Outside a branch they call the matching `Ash` function. `Ramal.Aggregate` holds the pure computation.

### Fixed

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

[Unreleased]: https://github.com/agustinrojas1/ramal/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/agustinrojas1/ramal/releases/tag/v0.1.0
