# Roadmap

Each milestone ships when its exit criteria hold, not on a date. Milestones are named for what they deliver, not for a version; [Releases](#releases) says which version carried which.

## 0.1 Core

The smallest Ramal that is useful and honest.

- `Ramal.Resource` extension with the read preparation and the write change, transparent when no branch is active.
- Ramal.Branch.Server, `Ramal.Supervisor`, registry, idle unload and rehydration.
- `branch/2`, `run/2`, `current/0`, `fork/2`, `diff/1`, `merge/2` (replay mode, `on_stale`), `discard/1`, `get/1`, `list/2`.
- `Ramal.Storage` behaviour with ETS and Postgres backends, `mix ramal.gen.migration`.
- Telemetry events as listed in the design.
- The `Farm` test domain, unit tests for the pure modules, property tests for the overlay, integration tests on Postgres.
- Documentation: README with a working example, module docs, the design document kept in sync, an ADR per
  **[confirm]** item resolved.

Exit criteria: `mix ci` green on CI; a host application can add the extension to its resources and the example in the
README runs as written; every **[confirm]** mark in `docs/DESIGN.md` is resolved into an ADR or a doc line.

## 0.2 Proposals and hardening

- `Ramal.propose/2`, `approve/2`, `reject/2`: a branch is frozen as a proposal that someone with the right to decide
  approves (which merges) or rejects, with the decision, the stale rows and the replay count stored on the branch. Done:
  a status and a field, not a `ramal_proposals` table (ADR 0012).
- Notifications policy inside branches (suppress by default, opt in per resource). Done in 0.1 (`notify_in_branch?`, ADR 0005).
- An explicit `Ramal.aggregate/4`. Done (ADR 0011): Ash exposes no hook to patch its own aggregates. It first computed on
  the patched list; it now aggregates in the database the rows the overlay does not touch and reads only the overlaid
  ones (ADR 0013), so scoring a state no longer costs a table scan.
- Many-to-many join resources inside a branch. Done: they get overlay entries like any resource; a many_to_many load and
  `manage_relationship` first did not see links the branch changed; they do since ADR 0017 (a paged load and a multi-hop `through` still do not).
- Several domains per branch. Closed: a branch names one domain, and resources of other domains that use `Ramal.Resource` are branched like the rest (`test/ramal/other_domain_test.exs`).
- Publish 0.2 to Hex. Done: `ramal` and `ramal_live` 0.2.0 are on Hex and the install snippets in the docs point at them.

## Inspector

Done; released with 0.2.0 in the `ramal_live` package.

- `ramal_live`, a separate package: a LiveView component showing open branches as columns, the diff per branch filling
  in live from telemetry, buttons to fork, merge, discard. This is the demo GIF. The page is done in `ramal_live/`
  (a router macro the host mounts in its own `live_session`, ADR 0015), with approve and reject for proposals. The demo
  app to record the GIF from is `ramal_live/examples/farm_demo.exs`; the recording itself is not in the repository.

## Benchmark

Done; released with 0.2.0 (`bench/` is not published to Hex).

- `bench/`: an agentic workload modelled on the one the
  [DAPLab article](https://daplab.cs.columbia.edu/general/2026/05/26/branchable-databases-arent-ready-for-agentic-workloads.html)
  focuses on, a Monte Carlo tree search that keeps forking promising partial states, mutates, queries and prunes. It
  runs against Ramal and two plain-Postgres baselines, including the cases where Ramal loses. Implemented; see
  `bench/README.md`. Ours is a fixed-shape tree search, not MCTS, and not a reproduction of their harness
  (BranchBench); their reported figures are cited as theirs in `bench/README.md` and never placed beside ours. Nothing in
  the README cites a number this project cannot reproduce.

## Agent tooling

Done; released in 0.3.0.

- `usage-rules.md` and a skill (`usage-rules/skills/ramal/`) that teach a coding agent to use Ramal, in the format of the
  `usage_rules` package.
- `Ramal.context/1` and `Ramal.Tools`: the branch calls as tools for any LLM tool loop or MCP server, without merge or
  approve (ADR 0019), and `docs/agents.md` with the wiring for a tool loop and for `AshAi`.
- Not done: an `ash_ai` extension, which would add a dependency on a fast-moving package.

## Releases

- 0.1.0: Core.
- 0.2.0: Proposals and hardening, the Inspector and the Benchmark.
- 0.3.0: Agent tooling, branch owners, the faster read, merge, aggregate and codec paths ([ADR 0020](adr/0020-read-selects-overlay.md)), and the fixes listed in `CHANGELOG.md`.
- 0.4.0: The `owner` column ([ADR 0021](adr/0021-owner-column.md)), the compact stored state ([ADR 0022](adr/0022-compact-state.md)), less memory per branch, faster fork and diff, the demo and Livebook tour, and fixes to calculations and the prefilter. Upgrade notes are in `CHANGELOG.md`.
- 0.5.0: Reads that agree with the branch: pages ([ADR 0030](adr/0030-pages-cut-from-the-patched-list.md)), aggregates ([ADR 0029](adr/0029-declared-aggregates-in-branches.md), [0032](adr/0032-aggregate-filters-and-sorts.md)), late-binding queries ([ADR 0028](adr/0028-late-binding-queries.md)), `Ramal.load/3` ([ADR 0031](adr/0031-ramal-load.md)), and the AshAi example. Upgrade notes are in `CHANGELOG.md`.
- 0.6.0: A branch in one tenant ([ADR 0034](adr/0034-one-tenant-per-branch.md)), and the formal verification under `verification/` (a TLA+ model checked with TLC and Bend 2 proofs) with the three bugs it found: running actions hold their writes ([ADR 0033](adr/0033-running-actions-hold-their-writes.md)) and the merged status is stored in the merge's transaction ([ADR 0035](adr/0035-merged-status-in-the-merge-transaction.md)). Upgrade notes are in `CHANGELOG.md`.
- 0.7.0: The remaining limits: bulk actions ([ADR 0036](adr/0036-bulk-actions-record-by-record.md)), result checks on patched rows ([0037](adr/0037-result-checks-run-on-the-patched-rows.md)), upserts ([0038](adr/0038-upserts-in-the-branch-view.md)), `first`, `list` and `uniq?` aggregates ([0039](adr/0039-first-list-and-uniq-aggregates.md)), relationship pages ([0040](adr/0040-relationship-pages-cut-per-source.md)), replay keys ([0041](adr/0041-replay-keeps-hook-keys-and-caller-attributes.md)), database-generated keys ([0042](adr/0042-placeholder-keys-for-generated-primary-keys.md)), nested branches ([0043](adr/0043-nested-branches-merge-into-their-parent.md)), clusters ([0044](adr/0044-branches-in-a-cluster.md)), text collation ([0045](adr/0045-text-sorted-by-the-databases-collation.md)), multi-hop `through` paths ([0046](adr/0046-through-paths-walked-over-the-branch.md)), relationship filter narrowing ([0047](adr/0047-relationship-filter-narrowing.md)) and durable branches ([0048](adr/0048-durable-branches.md)). Upgrade notes are in `CHANGELOG.md`.
- 0.8.0: Ramal's contract with Ash made explicit: the tested Ash range in `Ramal.Ash` with a boot warning outside it, tripwire tests for every Ash internal Ramal relies on, an Ash version matrix in CI, every limit on [limits.md](limits.md), and the [stability promise](STABILITY.md). No change in behaviour.
- 0.9.0: Ramal checks its Ash contract where it runs: `mix ramal.doctor` and, outside the tested range, a boot check that refuses branch work a broken assumption would affect with `:ash_incompatible` ([ADR 0049](adr/0049-ash-contract-checked-where-ramal-runs.md)). Every Ash internal Ramal touches now has a check. Ready for the next Ash's `through` paths, and a crash fixed on a `through` load left to the database.

## Formal verification

Done; released in 0.6.0.

- `verification/`: a TLA+ model of the branch lifecycle checked with TLC, and Bend 2 proofs of the overlay and merge rules, both run by a CI workflow. It found three bugs, fixed with ADR 0033 and ADR 0035.
- Not covered: the inspector, Postgres storage specifics, and the read paths of filters, sorts and relationships (tested by properties instead).

## 0.7 Remaining limits

Done; released in 0.7.0.

[limits-plan.md](https://github.com/agustinrojas1/ramal/blob/main/docs/limits-plan.md) gave the root cause and a design for each limit, and each one is closed by the ADR listed under Releases: bulk actions, `authorize_results`, upserts, paged and multi-hop relationship loads, aggregates, merge replay keys, database-generated keys, text collation, durable branches, relationship filter push-down, nested branches and clusters. The optional authorizer is not done: authorization stays the host's.

## Stability

The promise for the public API, and what may still change before 1.0, is in [STABILITY.md](STABILITY.md). From 0.8.0 nine
calls (`branch`, `run`, `fork`, `diff`, `merge`, `propose`, `approve`, `reject` and `discard`) keep their names, arguments
and return shapes through 0.x and into 1.0. Releases come when there is something worth releasing, a fix a user needs or
a set of features, not after every merge.

## 1.0

- Six months without a breaking change to the public API.
- At least two host applications in production shape.
- The inspector and the benchmark both released.

## Not planned

- Schema changes inside a branch.
- A query language or DSL of its own.
- Any dependency on a specific LLM provider or agent framework. Ramal is below that layer.
