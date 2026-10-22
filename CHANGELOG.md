# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/) once it reaches 0.1.

## [Unreleased]

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
- `Ramal.Storage.Postgres` and `mix ramal.gen.migration`: branches persist in a `ramal_branches` table and load back equal in a fresh VM. `Ramal.Storage.Codec` serializes a branch through the Ash embedded types without creating atoms. `Ramal.Storage.list/3` now returns `{:ok, branches} | {:error, error}`.
