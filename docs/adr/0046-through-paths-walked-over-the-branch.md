# 0046. A `through` path of several hops is walked over the branch's rows

Status: accepted, 2026-10-23. Amends [ADR 0017](0017-many-to-many-links-in-a-branch.md) and
[ADR 0040](0040-relationship-pages-cut-per-source.md).

## Context

A relationship with `through: [:herds, :moves]` is loaded with a lateral join on AshPostgres (`lateral_join?/4` in
`lib/ash/actions/read/relationships.ex`, Ash 3.37), and AshPostgres 2.15 joins the intermediate tables inside the
database (`lateral_join_query/3`, `build_through_queries/4`). The branch's rows on `herds` never took part: a move
created in the branch was missing, a herd moved to another paddock kept its moves in the old one, and a destroyed herd
kept its moves. A created row has no source in the join, so Ash dropped it.

The same code is wrong for a `through` path with a many_to_many hop (`through: [:herds, :vets]`): it joins
`vets JOIN herds ON herds.id = vets.id` and ignores the join resource, so the load is `[]` for every record with or
without a branch (`test/ramal/through_test.exs` pins it).

## Decision

- **Walk the path over the patched reads.** When the branch holds entries for a resource after the first hop, or for the
  destination, `lib/ramal/preparation/lateral.ex` replaces the lateral join. It keeps a map from a key value to the source
  records that reach it, starts with the sources' first `source_attribute`, and for each later hop reads the hop's entry
  query (Ash already hydrated it with the actor, tenant and shared context, so it goes through Ramal's preparation)
  filtered by `destination_attribute in ^reached`. On the last hop the destination read is filtered the same way and its
  rows are tagged with every source that reaches them, once per source, the way ADR 0017 and ADR 0040 tag theirs, so the
  per-source limit and offset, and the source tags Ash groups by, are the existing code's.
- **Left to the database:** a path with a many_to_many hop (upstream is wrong with or without a branch), a hop with a
  relationship filter, a `distinct`, and a `parent` expression in the relationship. Without overlay entries on the path
  nothing changes.
- **Pages.** Ash ignores `page:` on a `through` relationship (the load is a list of every row, in or out of a branch),
  so the branch does not page it either; `limit` and `offset` apply per source.
- The module is named `Lateral`, not `Path`, which would shadow Elixir's `Path`.

## Consequences

- A `through` load sees created, changed, moved and destroyed rows on every resource of the path, at the cost of one
  patched read per hop, only when the branch touched the path.
- The code depends on the shape of `lateral_join_source` for a path (one entry per hop; entry *i* reads the source
  resource of hop *i*), as ADR 0017 does; the tests pin it.
- The hops are read with the actor's authorization, as the entry queries were hydrated; the database joined them raw.
- Update, 2026-10-23: Ash after 3.37 expands a many_to_many hop into its join resource (Ash commit 3c4b41a), so the walk
  covers it with no change. A hop Ash reads with a limit or an offset joins the cases left to the database, and a load
  left to the database leaves out the rows the branch created instead of handing Ash a row it cannot group.
