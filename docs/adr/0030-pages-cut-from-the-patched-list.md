# 0030. A page is cut from the patched list

Status: accepted, 2026-10-23. Amends [ADR 0004](0004-read-patching-hooks.md).

## Context

Ash adds a page's limit and offset, or its keyset filter, after the `before_action` hooks (`paginate/3` in
`lib/ash/actions/read/read.ex`, Ash 3.37). A paginated read in a branch was therefore paged by the database and patched
afterwards: every overlay record was added to every page, so `Ash.page!(page, :next)` returned the same branch rows again
and `Ash.stream!/2` repeated them and lost base rows (issue 110). `count` was the database's, and `more?` came from the
database's rows.

## Decision

- **Page in Elixir when the overlay touches the resource.** The last `before_action` hook reads the whole patched list,
  cuts the page out of it and gives it to Ash with `Ash.Query.set_result/2`; `run_query/4` returns a set result instead
  of calling the data layer. The hook is added from the `before_transaction` hook, which runs before the query's
  `before_action` hooks are read, so it comes after those of every preparation and of the action.
- **Give Ash one row more than the page.** `drop_pagination_extra/3` takes the extra row and sets `more?`, and
  `add_keysets/3` puts the cursors on the rows, as for rows from the database. The count goes in the `full_count`
  context key, which `fetch_count/5` uses before it queries the database, and only when the page asked for a count.
- **Read the list with the action's own read.** the `read_all` helper of `Ramal.Resource` on a copy of the query without its page, hooks
  and relationship loads, with this preparation's `after_action` hook only, so the rest of the preparation (relationship
  filters, distinct, calculations, fingerprints) is the one an unpaged read uses. Loads, runtime calculations,
  authorization of results and field policies run once, on the rows of the page.
- **Keyset cursors are judged in Elixir.** `Ash.Page.Keyset.filter/4` builds the expression Ash would give the database;
  `Ash.Filter.Runtime` applies it to the patched rows, which the preparation sorted with the same stable sort Ash appends.
  A cursor is a sort value, not a row, so the cursor of a row the branch deleted still finds its place. Text compares as
  bytes, as the sort does (ADR 0024), so a cursor and the order agree.
- **Not changed:** with no overlay entry for the resource the database pages; a paged relationship load (Ash pages it
  per source record with a lateral join) is still paged by the database and patched afterwards.

## Consequences

- A page costs the read of every row the filter matches, as an unpaged read does. A list page over a large table inside
  a branch that changed that table is the expensive case; an attribute filter still narrows in the database.
- A user `before_action` hook added after the `before_transaction` hook ran is not seen; none of Ash's own are.
- The query's filter holds what policies added, and the list is read with `authorize?: false`; `authorize_results`
  checks and field policies run on the page.
