# 0004. Read patching: where it hooks in and what it does differently from the first design

Status: accepted, 2026-10-22. Issue: #4.

## Context

Design section 4.1 described the read patch in outline and left five Ash behaviours to confirm. They were checked
against Ash 3.37 (`deps/ash`).

## Decision

- **Where:** `Ramal.Preparation` is a global read preparation that, when a branch is current, adds a `before_action`
  and an `after_action` hook to the query. `before_action` hooks run after all preparations and before the
  data-layer query is built, so they can still remove `limit` and `offset`. `after_action` hooks receive the base
  rows before relationship loads, runtime calculations and the not-found check of `Ash.get/3`, so all of them see
  the patched rows.
- **Filter and sort:** `Ash.Filter.Runtime.filter_matches/4` evaluates the query's filter on the overlay records in
  one call. Ash.Actions.Sort.runtime_sort/3 sorts a list and has no comparator form, so the preparation calls
  `Overlay.patch/4` without `:sort`, `:offset` and `:limit`, then sorts, drops and takes itself. The design's plan to
  pass a comparator to `patch/4` stays valid for callers that have one; the preparation is not one.
- **No stripping without overlay entries:** when the overlay has nothing for the resource, the query keeps its limit
  and offset and Postgres pages. The design stripped them on every read in a branch; that made every read of an
  untouched table fetch all its filtered rows for no gain.
- **Select:** overlay records are whole structs, so they are trimmed to the query's `select` to match base rows.
- **Branch id in tasks:** the id is also written to the query's `shared` context (ADR 0002). Ash builds the first
  level of a load in the calling process but the levels below it in a task, so only the shared context reaches them.
- **Domain check at runtime:** `Ramal.branch/2` returns `:no_branchable_resources` instead of a compile-time domain
  verifier, which would require every host domain to add an extension.
- **Fingerprints are not recorded here.** They belong to issue 6 together with the diff that uses them.

## Consequences

- Paginated reads are paged by the database and then patched, so pages can be short or miss branch-created rows.
  Documented, not fixed, in 0.1.
- `authorize_results` checks do not run on overlay records; policy filters do, through the query's filter.
- Aggregates and database-computed calculations ignore the overlay and emit `[:ramal, :read, :unpatched_aggregate]`.
- The hooks call the branch server once per read (Ramal.Branch.Server.slice/2), and only the slice of that
  resource crosses the process boundary.
