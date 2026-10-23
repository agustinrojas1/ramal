# 0032. Filters and sorts on an aggregate see the branch

Status: accepted, 2026-10-23. Follows [ADR 0029](0029-declared-aggregates-in-branches.md) and
[ADR 0025](0025-relationship-filters-in-elixir.md).

## Context

ADR 0029 recomputed the aggregates a read loads and left a filter or sort on one to the data layer. The data layer
counts the base's related rows, so `filter herd_count >= 2` returned the paddocks the database counted two herds in
and missed the one the branch gave a third; a paddock created in the branch was judged by a database that has no such
row; and `sort herd_count: :desc` ordered by the database's numbers.

## Decision

An aggregate in a filter or sort counts as reaching every resource on its path, the way a relationship path does in
ADR 0025. The relationship-filter code treats a filter or sort ref whose attribute is an `Ash.Query.Aggregate` as having
the aggregate's `relationship_path`:

- when the branch has entries for a resource on that path, the conjunct is taken out of the data-layer query and
  evaluated in Elixir; the preparation computes the aggregates it names for the base rows it checks
  (`Aggregates.apply/3`, the same computation a loaded aggregate gets) before `Ash.Filter.Runtime` runs, which then
  finds them loaded;
- the overlay's records get the aggregates the filter names the same way, whether or not the path is touched: they come
  from the overlay without a value, and the runtime would ask a database that has not got them;
- a sort that names an aggregate is evaluated in memory: the aggregates are computed for the rows being ordered and the
  runtime sort reuses them. The rows returned keep only what the caller loaded.

`Aggregates` accepts the aggregates Ash hydrates for a filter or sort, which carry the destination's primary read action
in `read_action`; only another action still counts as custom.

## Consequences

- The numbers a filter or sort uses are the ones a loaded aggregate shows. A property test compares them with the count
  computed from the branch's herds for random creates, updates and destroys.
- A filter on an aggregate over a changed path reads every row the rest of the filter matches and one related read per
  aggregate for them (batched by Ash), where the database answered in one query. Keep attribute predicates beside it.
- The kinds and shapes ADR 0029 cannot compute (`first`, `list`, `custom`, `uniq?`, a join filter, a custom read action)
  keep the data layer's value for a filter too.
- `distinct` on an aggregate stays with the data layer: Ash 3.37 itself raises when asked (`Ash.Resource.Info.attribute/2`
  is called with the aggregate), so there is no form to support.
