# Ramal — working conventions

This file is the contract every contributor follows, human or agent. Read `docs/DESIGN.md` for what we are building and `docs/ROADMAP.md` for the order. This file is about how.

## What Ramal is

A library. No OTP application of its own beyond `Ramal.Supervisor`, which the host adds to its supervision tree. No Phoenix dependency in core, ever: UI lives in a separate package (`ramal_live/`). AshPostgres is optional. The public surface is `Ramal` plus the modules `docs/DESIGN.md` names as public; everything else is `@moduledoc false`.

## Layout

```
lib/ramal.ex                 public API (branch, run, fork, diff, merge, discard, current)
lib/ramal/ash.ex             Ramal's contract with Ash: the tested versions, the Ash internals it relies on, the seams that call them, the boot check (public)
lib/ramal/ash/contract.ex    the Ash contract as data: each assumption with its tier, feature, tripwire and check; ensure/1 refuses branch work (internal, ADR 0049)
lib/ramal/ash/probe.ex       the ETS resources and hooks the contract's checks run on; no Ramal.Resource (internal, ADR 0049)
lib/ramal/branch.ex          the Branch struct and pure functions over it
lib/ramal/branch/server.ex   GenServer: one process per open branch
lib/ramal/cluster.ex         the :via module over :global and the resolver for branches in a cluster (ADR 0044)
lib/ramal/current.ex         the current branch id of the calling process (process dictionary and Ash shared context)
lib/ramal/overlay.ex         the overlay map: apply, patch, diff (pure)
lib/ramal/resource.ex        Spark extension: adds the read preparation and the write change
lib/ramal/resource/transformer.ex  the extension's transformer (Spark needs a module for it)
lib/ramal/preparation.ex     read side: strip limit/offset, patch results
lib/ramal/preparation/aggregates.ex  aggregates a read loads, recomputed from the branch's rows after the patch (ADR 0029)
lib/ramal/preparation/related.ex  filters and sorts through a relationship the branch changed: split out of the data-layer query (ADR 0025), narrowed for to-one paths (ADR 0047)
lib/ramal/preparation/lateral.ex  a relationship load with a multi-hop `through` path, walked hop by hop over the branch's rows instead of the database's lateral join (ADR 0046)
lib/ramal/preparation/paged.ex   what page a query asks for and the cut of it from the patched list, so a paginated read in a branch is paged after the patch (ADR 0030)
lib/ramal/collation.ex       the database's collation for the text a branch sorts in Elixir: ranks from one query, so a sort and min/max of text agree with Postgres (ADR 0045)
lib/ramal/prefilter.ex       cheap test that rules overlay records out of a read filter before the Ash runtime does
lib/ramal/change.ex          the Change struct that diff returns
lib/ramal/aggregate.ex       aggregates: pure computation over records, and the database-plus-overlay delta of Ramal.aggregate/4
lib/ramal/capture.ex         write side: capture creates/updates/destroys into the overlay
lib/ramal/error.ex           the Error exception
lib/ramal/storage.ex         behaviour + Ramal.Storage.ETS, Ramal.Storage.Postgres
lib/ramal/storage/codec.ex   a branch to a JSON-safe map and back (pure)
lib/ramal/merge.ex           staleness check and replay
lib/ramal/merge/result.ex    the Result struct that merge returns
lib/ramal/limits.ex          the optional per-domain limits on creating branches and forks
lib/ramal/telemetry.ex       event names and helpers
lib/ramal/tools.ex           the branch tools for an LLM agent: definitions and call/3, no merge or approve (ADR 0019)
lib/mix/tasks/               ramal.install, ramal.gen.migration
lib/mix/tasks/ramal.doctor.ex  mix ramal.doctor: runs every Ash contract check on the host's Ash and exits 1 on a broken core one (public, ADR 0049)
test/support/farm/           the test domain (Paddock, Herd, Move) and its repo
docs/                        DESIGN.md, ROADMAP.md, agents.md (the guide for AI agents), ADRs under docs/adr/
usage-rules.md               rules for coding agents that use Ramal, in the `usage_rules` format (ships in the Hex package)
usage-rules/skills/ramal/    the skill for those agents (ships in the Hex package)
verification/                the TLA+ model (tla/) and the Bend proofs (bend/); check.sh runs both, README.md says what they prove
bench/                       a separate Mix project, never a dependency of the library
examples/ash_ai/            a separate Mix project that runs AshAi tools in a branch, pinned to one ash_ai version; depends on ramal
ramal_live/                  a separate Mix project, the LiveView inspector; depends on ramal, never the other way round
```

Do not add a module `docs/DESIGN.md` does not name without first adding it there with one line on why.

## Toolchain

- `mise.toml` pins Erlang and Elixir. Run everything through `mise exec -- mix ...` or activate mise in the shell.
- Postgres for tests: `docker compose up -d db` (host port **5435**, database `ramal_test`, user and password `ramal`). Two test runs at once must not share a database: give each its own `MIX_TEST_PARTITION=1`, `2`, ... (database `ramal_test1`, ...).
- `mix ci` must pass before every commit: format, compile with warnings as errors, credo strict, tests. Fix the cause, never silence a warning.
- Locked versions matter: Ash 3.36.x, AshPostgres 2.15.x, Spark 2.7.x. Before relying on an Ash hook or option, confirm it exists in the locked version's docs (`mix hex.docs offline ash` or the deps source under `deps/ash`). Write what you confirmed into the module doc. Do not guess APIs from memory.

## Code style

- Small modules, pure functions where possible. The overlay, diff and merge logic are pure and tested without a database; only the hooks and storage touch Ash or Ecto.
- Only `Ramal.Ash` touches an Ash internal (an `Ash.Actions` module, a `context.private` key, the lateral-join context); add a seam there with its tripwire test, never a direct call. `test/ramal/ash_seam_test.exs` enforces it. The exception is the contract under `lib/ramal/ash/`, whose checks name the internals on purpose (ADR 0049); a new assumption goes in `Ramal.Ash.Contract` with its tripwire test and its check.
- Every public module has a `@moduledoc` that says what it is for and one example. Every public function has `@doc` and a `@spec`. Private helpers need neither.
- Type and function names are English. The library name is Spanish; nothing else is.
- Errors are `{:error, %Ramal.Error{}}` with a `reason` atom and a message a developer can act on. Raise only in the bang variants.
- No speculative abstractions. If one storage backend exists, there is still a behaviour (it is in the design), but no plugin registry, no config DSL, no macros beyond the Spark extension.
- Comments explain why, not what. A rule that comes from an Ash limitation cites the doc or source line.
- Telemetry events for every branch lifecycle step; no logging from the library except at `:debug`, and the boot warning when the host's Ash or AshPostgres is outside the tested range (`Ramal.Ash`).

## Tests

- `mix test` runs against the real Postgres through the `Farm` test domain. Pure modules get unit tests with plain maps and structs, no database.
- Every bug fix adds a test that failed before the fix. Every hook has a test proving it is transparent when no branch is active.
- Property tests (StreamData) for the overlay: apply then diff round-trips, fork isolation, patch respects filters.
- Name tests by behaviour: `test "a read inside a branch sees rows created in that branch"`.

## Git

- `main` is always green. Work on short-lived branches named `kind/short-topic` (`feat/overlay-patching`, `fix/fork-shares-base`, `docs/merge-semantics`). One topic per branch, one pull request per branch.
- Commit subject: imperative, under 72 characters, with an area prefix: `core:`, `overlay:`, `storage:`, `merge:`, `live:`, `docs:`, `ci:`, `bench:`. Body says why and what was considered. No "WIP" commits on `main`.
- Only `git add` the paths you changed.
- Every user-facing change adds a line under `Unreleased` in `CHANGELOG.md` (Keep a Changelog format).
- A design decision that changes `docs/DESIGN.md` gets an ADR in `docs/adr/NNNN-title.md` (context, decision, consequences, half a page at most).

## Pull requests

- Title like the commit subject. Body: what, why, how it was tested, what is deliberately left out.
- CI green, `CHANGELOG.md` updated, docs updated in the same PR as the code.
- Do not bundle a refactor with a feature.

## Things to never do

- Never write to the database from inside a branch. The whole point is that nothing reaches the base until `merge/2`.
- Never create atoms from runtime data.
- Never add a dependency without a line in the PR body saying why it is worth it.
- Never claim a benchmark number in docs or README that `bench/` cannot reproduce.
