# 0040. A relationship page is cut from the patched rows, per source record

Status: accepted, 2026-10-23. Amends [ADR 0017](0017-many-to-many-links-in-a-branch.md) and
[ADR 0030](0030-pages-cut-from-the-patched-list.md).

## Context

A relationship loaded with a page, a limit or an offset (`Ash.Query.load(herds: query_with_page)`) is read by
AshPostgres as one lateral join that limits per source record (`lateral_join?/4` in
`lib/ash/actions/read/relationships.ex`, Ash 3.37). Ash then trims the extra row per source in
`drop_pagination_extra_per_parent/3` (`lib/ash/actions/read/read.ex`), before the `after_action` hooks, and builds one
page per source from `context.pagination_more_by_source` and the source's own `__paginated_<name>_count__` aggregate.
Ramal patched after all of that, and with a limit applied to the whole patched list. Inside a branch that changed the
destination:

- a row created, moved or renamed in the branch was missing from its source's page, and a destroyed one left it short;
- `limit` and `offset` were applied to the rows of all sources together, so `Ash.Query.limit(herds, 1)` returned no herds
  for any paddock once one herd had been created (its row has no source and Ash drops it);
- `more?` was the database's, and a many_to_many page ignored the branch's links altogether (ADR 0017 skipped paged
  loads).

## Decision

- **Rewrite the load when the branch changed what it reads.** For a lateral load with a page, a limit or an offset, the
  destination read hook (`lib/ramal/preparation/many_to_many.ex`) drops the lateral join when the branch holds entries
  for the destination, or, for a many_to_many, for the join resource. A has_many (any relationship of one hop with
  cardinality many) is read whole with `destination_attribute in ^source_values`; a many_to_many reads the patched join
  rows as ADR 0017 does. Each destination row is tagged with every source record that reaches it. A load with a
  `distinct`, a `parent` expression in the relationship's filter or sort, or cardinality one keeps the database's join.
- **Cut per source.** Without a page, the limit and offset are applied to each source's rows after the patch and the
  sort. With a page, the last `before_action` hook reads the whole tagged list, groups it by source and cuts each group
  with the same cut as a top-level page (offset, keyset `after`/`before`, `limit + 1` for `more?`; ADR 0030), and gives
  Ash the concatenation with `Ash.Query.set_result/2`. The query keeps the lateral join in its context, so Ash trims and
  builds the pages per source as for rows from the database.
- **The count is the source's.** `count: true` is the source record's aggregate, which the source read recomputes from the
  patched rows (ADR 0029). The count of a page Ash re-reads for one source (`Ash.page/2` with `:next`) is given by the
  hook, because Ash counts that read with a lateral query AshPostgres cannot build; the same call fails outside a branch.
- With no entry for the destination (and the join resource), nothing changes and the database pages.

## Consequences

- A page of related rows sees the branch's creates, updates, moves, destroys and links, and `count` and `more?` agree
  with the patched rows. `Ash.page!(page, :next)` works on a relationship page inside a branch.
- The cost is a read of every row of every source in the page, as for a top-level page (ADR 0030).
- The code depends on the shape of `lateral_join_source`, `__lateral_join_source__` and the `pagination_more_by_source`
  context key, as ADR 0017 does; `test/ramal/relationship_page_test.exs` pins them.
- A `through` path of several hops saw the base rows of its intermediate resources; [ADR 0046](0046-through-paths-walked-over-the-branch.md) fixes it.
