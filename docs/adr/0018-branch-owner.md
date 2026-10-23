# 0018. An optional owner on a branch, and an owner filter for `list/2`

Status: accepted, 2026-10-23. Follow-up to ADR 0016 (security defaults), which left per-user scoping to the host.

## Context

A branch id is the only capability to a branch, and `Ramal.list/2` returns every branch of a domain. A host that gives
each user their own branches had to keep its own table of who owns which id, and the inspector could only show everyone
everything or nothing. Ramal still cannot authorize a caller (it has no notion of users), but it can remember who the
host says a branch belongs to and filter by it.

## Decision

- **`%Ramal.Branch{}` has an `owner` field**, `nil` by default, set with `owner:` in `Ramal.branch/2` and `Ramal.fork/2`.
  A fork keeps its parent's owner unless given another. Ramal never interprets the value.
- **`Ramal.list/2` takes `owner:`.** Without the option nothing changes. With it only branches whose owner is `==` to the
  term are returned; `owner: nil` returns the unowned ones. `Ramal.list/2` checks the owner of what the storage returns,
  so a custom storage that ignores the filter cannot leak other owners' branches.
- **Storage:** the owner is written in the `state` JSON (`"owner"`), not in a column, so there is no migration and a
  branch stored by 0.2.0 loads as unowned. `Ramal.Storage.Postgres` filters on `state -> 'owner'` in SQL, so other
  owners' branches are not decoded; `Ramal.Storage.ETS` filters in memory. `c:Ramal.Storage.list/3` receives `:owner`
  in its filters only when the caller filters.
- **The inspector has an optional `:owner` route option**, `{module, function}`, called with the actor `:actor` returned.
  When given, the page lists, refreshes, forks and acts on that owner's branches only; when the actor or the owner is
  `nil` it shows nothing, because `nil` would match unowned branches. Off by default.
- **It is not access control.** `Ramal.get/1`, `diff/1`, `merge/2` and `discard/1` still take any id.

## Consequences

- The owner should be an id or a string, not a user record: it is stored with the branch (a record would store its
  password hash; the actor stored in the log has its `sensitive?` attributes removed, the owner does not) and compared with
  `==`. `Ramal.Branch` still prints only its identity, so the owner does not reach crash reports.
- Filtering by a term that is not a scalar compares its JSON form in Postgres, and the decoded owner again in Elixir; a
  map owner whose JSON form is not canonical can miss, never leak.
- No index: the filter is a scan of the domain's rows in `ramal_branches`, like the status filter. A column and an index
  are a migration for a host that lists often and has many branches, and can come later without changing this API.
- A host that wants enforcement checks `branch.owner` itself before `merge/2` or `discard/1`.
