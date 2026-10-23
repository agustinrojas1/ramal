# 0021. The owner is a generated column with an index

Status: accepted, 2026-10-23. Replaces the "no index" consequence of [ADR 0018](0018-branch-owner.md); the rest of that
decision stands.

## Context

`Ramal.list/2` with `owner:` filtered `ramal_branches` on `state -> 'owner'`, a scan of the domain's rows that had to
read every `state` document to compare it. A host that lists each user's branches often, with many stored branches,
wanted a real column and an index. Whatever we add must work for a table made by 0.2 or 0.3, with branches already
stored, and for a deploy in which an old node and a new node write the same table.

## Decision

- **`owner` is `jsonb GENERATED ALWAYS AS (NULLIF(state -> 'owner', 'null'::jsonb)) STORED`.** Postgres derives it from
  `state`, so there is no backfill to run, a row written by an old node is correct the moment it is written, and
  `Ramal.Storage.Postgres` writes nothing new (`state` stays the single source of truth; the column cannot disagree
  with it). An unowned branch, or one stored before owners existed, is `NULL`. It needs Postgres 12.
- **A partial hash index** on `owner` where it is not null. A btree entry cannot exceed about 2.7 kB and the owner is
  any term; a hash index stores a 4-byte hash, and the lookup is an equality. `owner: nil` is `owner IS NULL` and uses
  the `(domain, status)` index like the status filter.
- **`mix ramal.gen.migration` writes the migrations that are missing**: `create_ramal_branches` (unchanged) and
  `add_ramal_branch_owner`. A new install gets both; a host from 0.3.0 or earlier gets only the second, which uses
  `IF NOT EXISTS` and drops cleanly on rollback. Adding a stored generated column rewrites the table once.
- **Everything except the `owner:` filter works on a table without the column**, so upgrading the library before
  migrating breaks nothing at runtime but that filter, whose error says to run the task. `Ramal.Storage.ETS` is
  unchanged and keeps filtering in memory.

## Consequences

- The comparison is still on the JSON form of the owner, then checked again by `Ramal.list/2` on the decoded owner, as
  in ADR 0018: a map owner whose JSON form is not canonical can miss, never leak.
- A hand-written ramal table can add the same column and index by hand; the storage only needs a column called `owner`.
- Dropping the column on a rollback of the library is safe: nothing else reads it.
