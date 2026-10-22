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

- Ramal.propose/2: a branch becomes a proposal record (`ramal_proposals`) that someone with the right to decide
  approves (which merges) or rejects (which discards), with the diff and the staleness check stored at decision time.
- Notifications policy inside branches (suppress by default, opt in per resource).
- Runtime evaluation of simple aggregates over a branch where Ash exposes enough to do it; otherwise an explicit
  Ramal.aggregate/3 helper that computes on the patched list.
- Several domains per branch if a real host needs it.
- Publish 0.2 to Hex.

## 0.3 Inspector

- `ramal_live`, a separate package: a LiveView component showing open branches as columns, the diff per branch filling
  in live from telemetry, buttons to fork, merge, discard. This is the demo GIF.

## 0.4 Benchmark

- `bench/`: a reproduction of the DAPLab agentic workload (a tree search that keeps forking promising partial states,
  mutates, queries and prunes) against Ramal over plain Postgres. Published with the original numbers next to ours,
  including the rows where Ramal loses. Nothing in the README cites a number this project cannot reproduce.

## 1.0

- Six months without a breaking change to the public API.
- At least two host applications in production shape.
- The inspector and the benchmark both released.

## Not planned

- Schema changes inside a branch.
- Distributed branches across nodes.
- A query language or DSL of its own.
- Any dependency on a specific LLM provider or agent framework. Ramal is below that layer.
