# 0025. A filter or sort through a relationship the branch changed is evaluated in Elixir

Status: accepted, 2026-10-23. Amends [ADR 0004](0004-read-patching-hooks.md) and [ADR 0013](0013-aggregate-delta.md).

## Context

The preparation patches the rows of the resource being read. A filter that reaches another resource
(`paddock.name == "L07"`, `exists(paddock, ...)`, a sort on `paddock.name`) is judged by the data layer with a join against
the base's rows of that resource. When the branch renamed the paddock, the herds are untouched, so nothing was patched and
Postgres answered with the old name; when the herds also had entries, the base rows were judged by SQL on the base join and
the overlay rows by `Ash.Filter.Runtime` on the branch's paddock, so the two halves disagreed. The aggregate delta
inherited the same gap in its database part.

## Decision

- **Take the affected conjuncts out of the data-layer query.** The filter is split into the conjuncts of its top-level
  `and` chain. A conjunct with a ref through a resource the branch has entries for (any hop, and a many_to_many's join
  resource) is removed; the others stay, so Postgres still narrows the candidates. An `or` or a `not` is one conjunct.
  Removing conjuncts only widens the candidate rows. The sort through such a resource is also left to Elixir.
- **Evaluate them in Elixir.** A base row the branch did not change is checked against the removed conjuncts with
  `Ash.Filter.Runtime`; an overlay record is checked against the whole filter, as before. A sort through a changed
  resource loads the relationship and evaluates the calculation in memory first, and the runtime sort reuses the values.
- **Load the relationships first, with `reuse_values?: true`.** `Ash.Filter.Runtime` loads a relationship with
  `Ash.load/3`, which reselects the foreign key from the database without running the read hooks, so a record whose key the
  branch changed was judged by the old key (the limit documented in `Ramal.Preparation`). Loading first skips the reselect
  and goes through the patched reads.
- **The aggregate leaves the delta** for such a query and reads every matching row through the patched path.
- a helper in lib/ramal/preparation/related.ex plans this. A query whose refs reach no changed resource is untouched.

## Consequences

- A read like this fetches every row its kept conjuncts allow, and loads the relationship for each one the branch did not
  change. For OLTP-sized working sets that is fine; a filter through a relationship on a large table inside a branch that
  changed that relationship is the expensive case, and the host should keep such a branch rare or narrow the query with
  attribute predicates, which stay in the database.
- Row-level authorization of the related resource is not applied to these loads (`authorize?: false`), as for the
  runtime filter before.
- Aggregates and calculations declared on a resource still do not see the overlay (DESIGN 4.1 point 4).
