# Ramal — working conventions

This file is the contract every contributor follows, human or agent. Read `docs/DESIGN.md` for what we are building and `docs/ROADMAP.md` for the order. This file is about how.

## What Ramal is

A library. No OTP application of its own beyond `Ramal.Supervisor`, which the host adds to its supervision tree. No Phoenix dependency in core, ever: UI lives in a separate package (`ramal_live`, later). AshPostgres is optional. The public surface is `Ramal` plus the modules `docs/DESIGN.md` names as public; everything else is `@moduledoc false`.

## Layout

```
lib/ramal.ex                 public API (branch, run, fork, diff, merge, discard, current)
lib/ramal/branch.ex          the Branch struct and pure functions over it
lib/ramal/branch/server.ex   GenServer: one process per open branch
lib/ramal/overlay.ex         the overlay map: apply, patch, diff (pure)
lib/ramal/resource.ex        Spark extension: adds the read preparation and the write change
lib/ramal/preparation.ex     read side: strip limit/offset, patch results
lib/ramal/change.ex          the Change struct that diff returns
lib/ramal/capture.ex         write side: capture creates/updates/destroys into the overlay
lib/ramal/error.ex           the Error exception
lib/ramal/storage.ex         behaviour + Ramal.Storage.ETS, Ramal.Storage.Postgres
lib/ramal/merge.ex           staleness check and replay
lib/ramal/telemetry.ex       event names and helpers
lib/mix/tasks/               ramal.install, ramal.gen.migration
test/support/farm/           the test domain (Paddock, Herd, Move) and its repo
docs/                        DESIGN.md, ROADMAP.md, ADRs under docs/adr/
bench/                       a separate Mix project, never a dependency of the library
```

Do not add a module `docs/DESIGN.md` does not name without first adding it there with one line on why.

## Toolchain

- `mise.toml` pins Erlang and Elixir. Run everything through `mise exec -- mix ...` or activate mise in the shell.
- Postgres for tests: `docker compose up -d db` (host port **5435**, database `ramal_test`, user and password `ramal`).
- `mix ci` must pass before every commit: format, compile with warnings as errors, credo strict, tests. Fix the cause, never silence a warning.
- Locked versions matter: Ash 3.36.x, AshPostgres 2.15.x, Spark 2.7.x. Before relying on an Ash hook or option, confirm it exists in the locked version's docs (`mix hex.docs offline ash` or the deps source under `deps/ash`). Write what you confirmed into the module doc. Do not guess APIs from memory.

## Code style

- Small modules, pure functions where possible. The overlay, diff and merge logic are pure and tested without a database; only the hooks and storage touch Ash or Ecto.
- Every public module has a `@moduledoc` that says what it is for and one example. Every public function has `@doc` and a `@spec`. Private helpers need neither.
- Type and function names are English. The library name is Spanish; nothing else is.
- Errors are `{:error, %Ramal.Error{}}` with a `reason` atom and a message a developer can act on. Raise only in the bang variants.
- No speculative abstractions. If one storage backend exists, there is still a behaviour (it is in the design), but no plugin registry, no config DSL, no macros beyond the Spark extension.
- Comments explain why, not what. A rule that comes from an Ash limitation cites the doc or source line.
- Telemetry events for every branch lifecycle step; no logging from the library except at `:debug`.

## Tests

- `mix test` runs against the real Postgres through the `Farm` test domain. Pure modules get unit tests with plain maps and structs, no database.
- Every bug fix adds a test that failed before the fix. Every hook has a test proving it is transparent when no branch is active.
- Property tests (StreamData) for the overlay: apply then diff round-trips, fork isolation, patch respects filters.
- Name tests by behaviour: `test "a read inside a branch sees rows created in that branch"`.

## Git

- `main` is always green. Work on short-lived branches named `kind/short-topic` (`feat/overlay-patching`, `fix/fork-shares-base`, `docs/merge-semantics`). One topic per branch, one pull request per branch.
- Commit subject: imperative, under 72 characters, with an area prefix: `core:`, `overlay:`, `storage:`, `merge:`, `docs:`, `ci:`, `bench:`. Body says why and what was considered. No "WIP" commits on `main`.
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
