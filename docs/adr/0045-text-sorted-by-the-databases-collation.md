# 0045. Text sorted in a branch follows the database's collation

Status: accepted, 2026-10-23. Supersedes [ADR 0024](0024-text-sort-order.md). Amends
[ADR 0004](0004-read-patching-hooks.md).

## Context

Once the overlay touches a resource the preparation sorts the patched list in Elixir, where strings compare as bytes.
Postgres orders a text column by its collation: `en_US.UTF-8`, the default of the usual database and of CI, puts `apple`
before `Banana`, ignores punctuation at the first level and sorts by accent after letter. So the same read returned a
different order inside the branch and, after `Ramal.merge/2`, outside it (#169). ADR 0024 documented that and refused to
guess a collation, rightly: no Elixir comparator reproduces glibc or ICU, which are chosen per database and per column.
The database can answer the question, though, and a read inside a branch already holds a connection.

## Decision

- **Ask the database for ranks.** When a sort key is text and the resource is on AshPostgres, Ramal.Collation (`lib/ramal/collation.ex`) sends the
  distinct values of that key in one read-only query, `SELECT v, dense_rank() OVER (ORDER BY v COLLATE "<c>") FROM
  unnest($1::text[]) AS t(v)`, on the resource's repo, and the in-memory sort orders by the rank. Values equal under the
  collation share a rank, so the next sort key breaks the tie as it does in SQL. `nil`s and directions are placed as the
  runtime sort of Ash places them (`:asc` last, `:desc` first, and the four `_nils_` variants).
- **The collation is the column's.** It is read from `pg_attribute.attcollation` and `pg_collation`, once per table and
  column, and kept in `:persistent_term`; a resource with schema-per-tenant tenants reads it on every sort, because the
  same column can differ between tenants. A column altered with `COLLATE` is seen after a restart.
- **Byte order is not queried.** A column of collation `C`, `POSIX` or `ucs_basic` is already in byte order. A `citext`
  column ranks by `lower(v)`, as the type compares. A key that is not a column (an expression calculation, an aggregate of
  something else) is ranked by the database's default collation. A sort through a relationship
  (`Ash.Sort.expr_sort(parent.name, :string)`) uses the collation of the related column. Another data layer keeps byte
  order, and so do numbers, dates and every key that is not text.
- **The three sort sites share it**: the plain sort, the pick order of a `distinct`, and the in-memory sort through a
  changed relationship or an aggregate (`Ramal.Preparation`). `Ramal.aggregate/4` and the declared aggregates use it for
  `:min` and `:max` of a string, where the database's value and the branch's are ranked together; `first` and `list` read
  rows already sorted by the read.
- **A failed query is an error**, `{:error, %Ramal.Error{reason: :collation_failed}}`, and not a quietly wrong order.

## Consequences

- A text sort in a branch costs one more round trip per text key, of the size of the distinct values the read sorts.
  Reads that sort on numbers, dates or keys, and reads of resources the overlay does not touch, are unchanged.
- The query is read-only, so the rule that a branch never writes to the database holds. It runs on the connection the
  calling process holds, so it joins a transaction or a sandbox the read is in.
- **Two gaps remain, both byte order.** A keyset cursor on a text sort is compared by the filter Ash builds from the
  cursor (`Ash.Page.Keyset.filter/4`), which `Ash.Filter.Runtime` evaluates on bytes, so a keyset page after a mixed-case
  cursor can skip or repeat rows: page a text sort by offset, or sort by a key that is not text and end with it. And a
  comparison filter on text (`name > "b"`) is evaluated in Elixir for the branch's rows, in bytes, where the database
  compares by collation; equality, `in` and `contains` are not affected.
- The ADR 0024 test that pinned byte order now pins the database's order. Tests compare the branch's order with the
  database's after the merge for a column of each kind (default, `C`, ICU and `citext`) and with literal orders for the
  two that do not depend on the server's locale.
