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

## Formal verification

Done; released in 0.6.0.

- `verification/`: a TLA+ model of the branch lifecycle checked with TLC, and Bend 2 proofs of the overlay and merge rules, both run by a CI workflow. It found three bugs, fixed with ADR 0033 and ADR 0035.
- Not covered: the inspector, Postgres storage specifics, and the read paths of filters, sorts and relationships (tested by properties instead).

## 1.0

- Six months without a breaking change to the public API.
- At least two host applications in production shape.
- The inspector and the benchmark both released.

## Not planned

- Schema changes inside a branch.
- Distributed branches across nodes.
- Nested branches, upserts inside a branch, and database-generated keys. Each is refused with a clear error.
- A query language or DSL of its own.
- Any dependency on a specific LLM provider or agent framework. Ramal is below that layer.
