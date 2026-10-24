# 0042. Placeholder keys for database-generated primary keys

Status: accepted, 2026-10-23. Amends [ADR 0005](0005-write-capture.md) and [ADR 0007](0007-merge.md).

## Context

A create whose primary key only the `INSERT` can give (`integer_primary_key`, a `generated? true` attribute, a column
default such as `gen_random_uuid()`) has `nil` for its key after `apply_attributes/2`. The overlay and the log are keyed
by primary key, so the capture refused such a create with `:database_generated_key`. Those are the most common keys of
an existing application, so a host with them could not use a branch for creates.

## Decision

- The capture gives the row a **placeholder key** when the primary key is a single `generated? true` attribute of type
  `Ash.Type.Integer`, `UUID` or `UUIDv7`. An integer key gets `-2_147_483_648 + n` for the branch's `n`th placeholder: the
  value fits `int4` and `int8`, so a filter on it reaches Postgres without overflowing, and generated keys are positive.
  A UUID key gets a fresh UUID. The counter is `next_placeholder` on `%Ramal.Branch{}`, copied by a fork (each fork's
  placeholders are its own, so two forks may reuse a value, which is harmless because each is renamed at its own merge),
  stored by the codec, and `0` when a stored branch has none. Any other type, a composite key and a key that is not
  `generated?` are still refused, with a message that says which.
- The placeholder goes on the record and, with `force_change_attribute`, on the changeset, so after-action hooks see it.
  The log entry carries `generated_key?: true`.
- The merge replays such a create **without forcing the key**, and learns the real key from the record the action
  returned. Before it replays any later entry it replaces every exact occurrence of a placeholder in the input (maps,
  lists and tuples at any depth) and in the entry's `:key`. A key that arrives as text (a form sends `"-2147483647"`) is
  matched as text and replaced by text. Placeholders are unique within a branch, so a value names its row.
- `Ramal.Merge.Result` gains `keys: %{{resource, placeholder} => real_key}`, and `records` is keyed by the real key.

## Consequences

- A create with a generated key works in a branch: it can be read, updated and destroyed there, and a row created in the
  same branch can refer to it by a foreign key, which the merge rewrites.
- The placeholder is visible before the merge, in the record the action returns, in `Ramal.diff/1` and in what an agent
  sees. It is not the key the row will have; `Result.keys` maps it to the real one.
- A placeholder that a hook of another captured action stores outside the action's input, such as inside a JSON blob
  or an attribute the action computes, is not renamed.
- A row a hook creates (`nested?`) with a placeholder key is renamed too, once the replay of its outermost action
  creates it again (ADR 0041): the key plan lists it as `{:generated, placeholder}`, so the capture change forces no key
  on that create and records the key the database gives, and the entries after it name the row by that key. The
  attributes a caller set after `for_*` (`forced`) are renamed like the input. A bulk action (ADR 0036) is one captured
  action per record, each with its own placeholder; an upsert (ADR 0038) that finds its row, in the base or in the
  branch, takes that row's key and hands out no placeholder.
- A real value that equals a placeholder (an integer near `-2^31` in user data) is renamed by mistake once a placeholder
  of that value exists in the log. A `smallint` key column is not supported: the placeholder does not fit it.
- A sort or keyset page on a single generated integer key orders a placeholder **after every real key**, in creation
  order (before them for `:desc`), which is where the merge puts the row: the sequence gives it a key above every
  existing one. The sort and the cursor comparison run in Elixir on the patched list, so `Ramal.Preparation.Placeholders`
  lifts a placeholder `-2^31 + n` to `2^63 + n` (above any `int8`) for the comparison and restores it afterwards: the
  rows, the cursors Ash puts on them and `Ramal.diff/1` keep the placeholder. A keyset cursor that names a placeholder
  has the value in its comparisons lifted the same way. This matches the merged order when the sequence is above every
  base key and the branch's creates replay in creation order, which the merge does. A UUID placeholder is random and a
  real UUID's position is not creation order either, so UUID keys are out of scope: their position in a sort is
  arbitrary until the merge. A comparison filter on the key (`id > 5`) still sees the negative number, and a sort
  through another resource's key (`parent.id`) is not lifted.
- A data layer that does not generate the key (`Ash.DataLayer.Ets` with `integer_primary_key`) accepts the create in the
  branch and fails it at the merge.
