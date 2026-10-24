# 0054. A fragment filter is judged by the database on the branch's rows

Status: accepted, 2026-10-24. Amends [ADR 0004](0004-read-patching-hooks.md).

## Context

A read in a branch lets the database narrow the base rows and then judges the rows the branch created or changed in
Elixir, with `Ash.Filter.Runtime`. The runtime cannot run a `fragment(...)`: the SQL text is the database's. It gives
"unknown", and a filter treats unknown as no match (#218). So after a branch raised a paddock's `capacity_head` to 500,
`capacity_head > 80` found it and `fragment("? > 80", capacity_head)` did not, with no error. The opposite miss was
there too: a row the branch changed that still satisfied the fragment was replaced by its overlay record and dropped.
Real Ash apps filter by fragments often (jsonb, full-text search, PostGIS), so this was silently wrong where it matters.

## Decision

- **Evaluate, don't refuse.** The conjuncts of the filter that hold a fragment (directly, under an `exists`, or in an
  expression calculation) are judged by Postgres on the overlay's records. The records are sent as an inline table:
  the query Ash builds for those conjuncts gets a common table expression with the name of the resource's table,
  `WITH "paddocks" AS (SELECT ... FROM (VALUES (...), ...) AS v0 (...))`, which shadows the table for that one query.
  The fragment, the calculations and the joins to resources the branch did not change are the database's own, and the
  query reads only. Ash and Ecto build the query (`Ash.Query.data_layer_query/2`, `Ecto.Query.values/2`,
  `with_cte/3`), so no SQL is written by hand.
- **The rest is unchanged.** A record must pass the fragment conjuncts (database) and the other conjuncts (Elixir), as
  the conjuncts of an `and` do. A filter with no fragment takes the old path and costs nothing more.
- **Refuse where the answer would be wrong**, with `{:error, %Ramal.Error{reason: :fragment_unsupported}}`: a resource
  on a data layer other than AshPostgres, a table the CTE cannot shadow (a `schema`, a schema-per-tenant tenant, a
  polymorphic table), a fragment conjunct that reaches a resource the branch changed (the database would join the
  base's rows), and an attribute type with no SQL parameter type.
- **Base rows are not sent.** A row the branch did not touch is judged by the database already, in the base query.

## Consequences

- A read in a branch with a fragment filter costs one more query when the branch changed the resource, of the size of
  the overlay's records the prefilter lets through.
- A sort or an aggregate that holds a fragment is not covered (the runtime cannot evaluate it either); it is listed in
  `docs/limits.md`.
- The assumption that `Ash.Filter.flat_map/2` visits a filter's nodes is in `Ramal.Ash` with a tripwire test.
