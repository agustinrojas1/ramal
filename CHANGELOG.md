# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/) once it reaches 0.1.

## [Unreleased]

### Added

- Project scaffold: design document, roadmap, conventions, CI, test database setup, logo.
- `Ramal.Overlay`: the pure overlay of a branch (put, slice, patch, diff, merge for forks), `Ramal.Change` and `Ramal.Error`.
- Branch processes: `Ramal.Supervisor`, `Ramal.branch/2`, `run/2`, `run!/2`, `current/0`, `get/1`, `list/2` and `discard/1`, with idle unload, transparent rehydration, a heap limit, and telemetry for the branch lifecycle.
- `Ramal.Storage` behaviour and the `Ramal.Storage.ETS` backend.
- `Ramal.Resource` extension and `Ramal.Preparation`: reads inside a branch see rows created, updated and deleted in it, with limit, offset, sort, select and relationship loads applied to the patched rows. Telemetry for `[:ramal, :read, :patch]` and `[:ramal, :read, :unpatched_aggregate]`.
- `Ramal.branch/2` returns `:no_branchable_resources` for a domain none of whose resources opted in.
