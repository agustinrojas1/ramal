# Roadmap

Milestones are GitHub milestones with the same names. Each one ships when its exit criteria hold, not on a date.

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
- An explicit `Ramal.aggregate/4` that computes on the patched list. Done (ADR 0011); Ash exposes no hook to patch its own aggregates.
- Several domains per branch if a real host needs it.
- Publish 0.2 to Hex.

## 0.3 Inspector

- `ramal_live`, a separate package: a LiveView component showing open branches as columns, the diff per branch filling
  in live from telemetry, buttons to fork, merge, discard. This is the demo GIF. The page is done in `ramal_live/`
  (a router macro the host mounts in its own `live_session`, ADR 0014), with approve and reject for proposals; the demo
  GIF comes with the demo app.

## 0.4 Benchmark

- `bench/`: an agentic workload modelled on the DAPLab description (a tree search that keeps forking promising partial
  states, mutates, queries and prunes) run against Ramal and two plain-Postgres baselines, including the cases where
  Ramal loses. Implemented; see `bench/README.md`. The DAPLab article was not reachable when it was written, so it
  is not a reproduction of their harness and quotes none of their figures. Nothing in the README cites a number this
  project cannot reproduce.

## 1.0

- Six months without a breaking change to the public API.
- At least two host applications in production shape.
- The inspector and the benchmark both released.

## Not planned

- Schema changes inside a branch.
- Distributed branches across nodes.
- A query language or DSL of its own.
- Any dependency on a specific LLM provider or agent framework. Ramal is below that layer.
