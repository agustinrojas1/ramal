# 0006. Fingerprints, snapshots and fork

Status: accepted, 2026-10-22. Issue: #6.

## Context

Design sections 3, 7 and 8 describe fingerprints (for the staleness check at merge) and snapshots (for `diff/1`) as
two things kept "alongside" each other without fixing a shape, and say a fork copies the fingerprints.

## Decision

- **Shape:** `branch.base` is `%{{resource, key} => %{fingerprint: integer | nil, snapshot: record | nil}}`. One map,
  one entry per touched base row, so a row is never described twice.
- **When:** the read preparation fingerprints every base row a read returns, before patching, in one call to the branch
  process per read. The first write to a row adds its snapshot and keeps the fingerprint an earlier read took, because
  staleness is measured from the first touch. A row is fingerprinted only when every attribute is loaded; a read with
  `select` skips it, as its hash would never equal a full read's.
- **What:** `:erlang.phash2` of the attribute map (`Ramal.Resource.attributes/1`, which leaves out relationships,
  calculations, aggregates and unloaded attributes), not of the struct, whose metadata differs between reads.
- **Cost:** a read inside a branch hashes its rows and sends a map of `{ref, hash}` to the branch process. Not measured;
  `bench/` will, before the README says anything about it.
- **Diff:** `Ramal.Branch.diff/2` is pure; `Ramal.diff/1` passes the Ash-aware attributes function. Order is the log
  order of first touch, and rows the log does not mention come last.
- **Fork:** `Ramal.Branch.fork/2` keeps overlay, log and base and changes id, `inserted_at`, name (default: the
  parent's) and metadata (default: the parent's, plus `forked_from`). It starts a process like `branch/2` and emits
  `[:ramal, :branch, :fork]` followed by `:load`.
- **Write replies:** `Server.write/2` replies with `%{id, domain}` instead of the whole branch, so a captured write no
  longer copies the overlay back to the caller. `update/2` still does.

## Consequences

- A partially selected read gives merge less to compare; rows only ever read that way are not checked for staleness.
- Reads that load many rows pay a hash per row. Relationship loads are reads too, so they are fingerprinted.
- Forking does not check that the parent's rows still match the database; merge does.
