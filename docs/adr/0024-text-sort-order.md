# 0024. A text sort inside a branch is byte order, and Ramal does not guess a collation

Status: accepted, 2026-10-23. Amends [ADR 0004](0004-read-patching-hooks.md).

## Context

Once the overlay touches a resource, the preparation sorts the whole patched list in Elixir with
`Ash.Actions.Sort.runtime_sort`, which compares binaries. Postgres orders text by the collation of the database or
the column (`en_US.UTF-8` puts `apple` before `Banana`; `C` is byte order). So the same query outside and inside a
branch can return mixed-case text in a different order, and `Ramal.aggregate/4` with `:min` or `:max` on a string
mixes the two orders for the same reason. Numbers, dates and booleans are not affected, nor is null placement.

## Decision

- **Document it** as a limit: DESIGN 4.1, the README limits, the preparation's module doc and `Ramal.aggregate/4`.
- **Pin it with a test** that sorts mixed-case names inside a branch, so the day it changes is visible.
- **No comparator option.** No call in the standard library reproduces a Postgres collation (it is ICU or glibc, chosen
  per database or per column, and it differs between servers). A `:unicode` option would be a third order that matches
  neither `C` nor the usual `en_US`, and a host-supplied function would need the host to know which collation its
  database uses and keep the two in step. Keeping the database's order for base rows and inserting overlay rows with a
  guess is wrong as soon as the guess differs.

## Consequences

- Hosts that sort user-visible text in a branch and care about case or accents get byte order; sorting on a numeric,
  date or key column is exact. A host that needs the database's order can read the sorted ids outside the branch.
- If a host asks for a comparator we reopen this with a concrete collation to match; the preparation has one place
  that sorts (`sort/2`), so the option would be small.
