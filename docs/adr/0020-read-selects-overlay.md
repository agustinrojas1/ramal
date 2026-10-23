# 0020. A read takes only the overlay entries it can use

Status: accepted, 2026-10-23. Supersedes the "overlay slice" wording of [ADR 0004](0004-read-patching-hooks.md); the hooks
and the result of a patched read are unchanged.

## Context

Profiling the benchmark (`bench/`) showed that the cost of a read inside a branch grew with the size of the overlay even
when the read returned a handful of rows. At 1,000 overlaid rows a read of 1% of the table took 9.0 ms against 1.9 ms
with an empty overlay, and an `Ash.get` followed by an update took 6.9 ms against 1.35 ms. Three costs, all
proportional to the overlay:

1. `Ramal.run/2` fetched the whole branch (overlay, log and base) from its process to check that it was open.
2. Every read copied the resource's whole overlay slice from the branch process to the caller.
3. Every read ran `Ash.Filter.Runtime.filter_matches/4` on every overlay record of the resource, at about a
   microsecond each, to find the ones that satisfy the filter.

## Decision

1. Ramal.Branch.Server.status/1 returns the status alone, and `run/2` and `fork/2` use it.
2. A read first asks `Server.overlay?/2` whether the branch holds any entry for the resource (the question that decides
   whether to strip `limit` and `offset`), and after the database answers it asks `Server.select/4` for what it needs:
   the entries of the primary keys the base returned, and the records that may satisfy the filter. The process runs
   `Ramal.Overlay.select/4` on its own overlay, so only those entries cross the process boundary.
3. Ramal.Prefilter compiles the query's filter to plain data and tests a record with ordinary comparisons. It answers
   `false` only when the filter surely rejects the record: a comparison (`==`, `!=`, `<`, `>`, `<=`, `>=`), `in` or
   `is_nil` of an attribute against a literal, under `and`, `or` and `not`, with both sides loaded and both binaries,
   both integers or both atoms, which is where `Comp` in Ash 3.37 is the plain Elixir operator. Anything else
   (relationship paths, functions, calculations, aggregates, `nil`, unloaded values, decimals, dates) is unknown and
   goes on to the real runtime. A base row whose overlay record is ruled out arrives as `:deleted`, which drops the
   row just as a failed predicate would.

The runtime still decides every record the prefilter lets through, so the result of a read is what it was.

## Consequences

- The cost of a read follows what it returns plus one pass over the overlay of the resource inside the branch process
  (pattern match and a comparison per entry), not a copy of the overlay and a runtime evaluation per entry.
- The slice is read at two moments, when the query is prepared and when the rows come back, instead of once. A write
  by another process in between is seen by the second read, which is the same race a read has with the database.
- A filter shape the prefilter does not understand costs what it cost before. Adding one is a pure function and a
  property test against `Ash.Filter.Runtime` (`test/ramal/prefilter_test.exs`).
- The branch process now evaluates the prefilter for the readers, so a very large overlay makes that pass the
  serialised part of a read. An index by resource inside the process is the next step if the benchmark shows it.
