# 0049. Ramal checks its Ash contract where it runs

Status: accepted, 2026-10-23. Builds on the tested range and tripwires of 0.8.0 (`Ramal.Ash`, `test/ramal/ash_contract_test.exs`).

## Context

Ramal works above Ash's data layer and relies on Ash behaviour that is internal or undocumented: a result set in the
last `before_action` hook skips the data layer, bulk actions run an `around_action` changeset one record at a time,
`context.private` carries the upsert keys, and so on. `Ramal.Ash` lists every such assumption and owns every touch of
one, and CI checks each with a tripwire test on Ash 3.36, 3.37, the latest 3.x and `main`. That protects the versions CI
reaches. A host that upgrades Ash past the tested range only gets a warning at boot: if an assumption broke, the first
sign would be a branch write that reached the database or a read that showed the wrong rows.

## Decision

- **The contract ships with the library.** Ramal.Ash.Contract (internal) lists each assumption as data: an id, a
  tier, the feature it serves and a check. The checks run against small resources on `Ash.DataLayer.Ets` compiled into
  the library (Ramal.Ash.Probe, which do not use `Ramal.Resource` and need no repo or config), so they test the
  host's Ash, not ours. The tripwire tests stay in the suite for what needs Postgres; a test runs the shipped checks
  and requires them all to pass on the locked versions.
- **Two tiers.** The core contract is what single-record create, update and destroy, patched reads, fork, diff, merge
  and propose need. The extended contract is grouped by the feature that needs it: `:bulk`, `:upsert` and
  `:relationship_pages` (paged, lateral and many-to-many loads walked over the branch). The core list fits on one screen
  in `Ramal.Ash`'s docs.
- **`mix ramal.doctor`** runs the checks and prints one line per assumption with its tier, feature and result, and the
  host's Ash and AshPostgres against the tested range. It exits with status 1 when a core assumption is broken, so a
  host upgrading Ash learns it in dev or CI, before anything can write.
- **At boot, only outside the tested range.** Inside the range CI has run the checks already, so boot costs nothing.
  Outside it, `Ramal.Supervisor` runs them once (milliseconds, in memory), logs which are broken next to the existing
  version warning, emits `[:ramal, :ash, :contract]`, and keeps the broken ids.
- **Fail closed, per tier.** With a core assumption broken, every read and write inside a branch is refused with the
  new `Ramal.Error` reason `:ash_incompatible`, whose message names the assumption and says to run `mix ramal.doctor`.
  With an extended one broken, only that feature is refused: a bulk action, an upsert, or a relationship load the
  branch would have to walk. Everything else keeps working, so the extended contract can lag an Ash release without
  blocking the core. Outside a branch nothing changes: Ramal's hooks stay transparent.

## Consequences

- An Ash release that breaks an assumption makes Ramal refuse instead of writing to the database or reading the wrong
  rows, on the host's own version, with the assumption named.
- The probe resources are compiled into every host. They are small, never started, and live in a domain that is not
  part of the host's configuration.
- An assumption the shipped checks cannot exercise without Postgres stays a tripwire only; `Ramal.Ash` marks which.
- Upstream asks (`/ash-upstream` drafts) shrink the list over time: each one Ash makes public turns a check into a
  documented contract.
