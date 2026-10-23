# 0016. Security defaults: fail closed, print nothing a branch holds, read storage defensively

Status: accepted, 2026-10-22. Follow-up to ADR 0010 (stored actors) and ADR 0015 (the inspector).

## Context

A review of the library and the inspector found no injection (every SQL value is a bound parameter, the table name is a
constant) and no advisory in any lockfile. It found four places where a default was more permissive than it needed to
be: the inspector printed the values of `sensitive?` attributes in a diff; it acted with no decider when the host's
`:actor` function found nobody signed in; `inspect/1` of a branch, and so a crash report of its process, printed the raw
input of every captured write; and a malformed `state` column crashed the caller instead of returning an error.

## Decision

- **The inspector redacts `sensitive?` attributes** (`[redacted]` for before and after). The row stays so the reviewer
  sees that it changed. Same flag as ADR 0010; no second list.
- **A configured `:actor` that returns `nil` means nobody is signed in**, and the page refuses every action. Without the
  option nothing changes: the host has not said the page acts for anyone.
- **`Ramal.Branch` derives `Inspect` with `only: [:id, :name, :domain, :status, :inserted_at]`.** Ash redacts sensitive
  attributes of records but not action input, which the log must keep to replay.
- **`Ramal.Storage.Codec.decode_state/2` never raises and never echoes stored values.** It reports the kind of
  exception, rejects a module name that is not shaped like one before it reaches `:code.where_is_file/1`, and rejects a
  stored struct whose module has no `__struct__/0`.
- **CI runs `mix hex.audit`** in the three projects.
- **Follow-up, 2026-10-23: the inspector's `:actor` is required** (it was left optional above so that no host broke).
  `ramal_inspector` raises `ArgumentError` at compile time without it, and the page raises when it opens if the function
  does not exist (the module may not be compiled yet when the router is). There is no opt-out: a host with no users
  passes a function that returns a constant.
- **Follow-up, 2026-10-23: optional limits on creating branches.** `Ramal.Supervisor` takes `:max_active_branches` (open
  and proposed branches per domain) and `:branch_rate` (`{count, milliseconds}`: creations per domain per fixed
  window); `Ramal.branch/2` and `Ramal.fork/2` return `{:error, %Ramal.Error{reason: :limit_reached}}` past either and
  emit `[:ramal, :limit, :reached]`. Both are off by default. Counting uses a new optional `c:Ramal.Storage.count/3`
  (one query with Postgres, `list/3` for a backend without it). Limits are per domain, not per user, and the first is
  soft under concurrency: user scoping stays with the host.
- **Follow-up, 2026-10-23: an optional owner.** A branch can carry an `owner` set at `branch/2` or `fork/2`;
  `Ramal.list/2` takes `owner:` and the inspector takes an `:owner` option, both off by default, so a host can show each
  user their own branches. It is a filter, not access control (ADR 0018).
- Not changed: the ETS tables stay `:public` (every branch process writes to them) and branch ids stay the only
  capability to a branch (an owner filters `list/2`; it does not guard `get/1`). Both are documented in `SECURITY.md` as the host's boundary.

## Consequences

- A `ramal_inspector` call without `:actor` stops compiling until it names one. The inspector first ships in 0.2.0, so
  no released version is affected.
- A host that turns on a limit must handle `:limit_reached` from `Ramal.branch/2` and `Ramal.fork/2`; the inspector
  already shows any error from a fork on the page.
- An `:actor` function that legitimately returns `nil` for a service account must return a value for it instead.
- Debugging a branch in IEx shows less; read `branch.log` and `branch.overlay` on purpose.
- The inspector cannot show a sensitive value to someone who needs to review it. They can read it from the record.
- A mount-per-`live_session` rule remains for inspectors with different audiences: the page reads its options from the
  URL the browser joins with, which LiveView checks against the session's view and live_session name only.
