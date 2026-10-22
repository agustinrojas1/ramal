# 0008. Postgres storage and the codec

Status: accepted, 2026-10-22. Issue: #8.

## Context

Design section 6 left two **[confirm]** marks (`Ash.Type.dump_to_embedded/3`, `Ash.Type.cast_stored/3`) and described
actors as stored through a host `Ramal.Actor` serializer. A branch also holds terms no Ash type covers: action input,
primary keys, metadata and log options.

## Decision

- **Confirmed (Ash 3.37, `lib/ash/type/type.ex`):** the pair is `dump_to_embedded/3` and `cast_from_embedded/3`, not
  `cast_stored/3`. `cast_stored` reads the data layer's native form; the embedded pair is the JSON-safe one. Several
  types dump to a non-JSON value (`DateTime`, `Date`, `Decimal`, `Ash.Type.Term` as a binary), so the result still goes
  through the term encoder below.
- **Codec:** `Ramal.Storage.Codec` (pure, no database) turns a branch into a JSON-safe map and back; any backend that
  stores text can use it. Attributes use the Ash type pair. Everything else is a tagged term (`$a` atom, `$t` tuple,
  `$m` map as pairs, `$s` struct, `$b` base64). The rest of a record (`__meta__`, `__metadata__`, loaded relationships)
  is kept only when it differs from a fresh `struct(resource)`, so a round trip is `==`.
- **Atoms are never created from stored data.** Atoms are read with `String.to_existing_atom/1`. A module name that is
  not an atom yet is looked up on the code path and created only when a beam file exists for it; naming a module also
  loads it so that the atoms it mentions exist. Ramal's own option names are matched explicitly. An atom nothing has
  loaded fails the load with `:storage` and names the atom.
- **Actors are stored as the term they are**, not through a serializer. The design's host callback is a plugin point
  with one use; `Ramal.merge/2` already takes `actor:` for hosts that do not want an actor persisted. The consequence is
  that an actor struct is stored whole, secrets included.
- **Table:** `ramal_branches` with `id uuid`, `domain`, `name`, `status`, `state jsonb`, `inserted_at`, `updated_at`,
  an index on `(domain, status)`. `mix ramal.gen.migration` writes it into the host repo; the module and the task exist
  only when Ecto SQL is present. Ids must be UUIDs (what `Ramal.Branch.new/2` makes).
- **`Ramal.Storage.list/3` returns `{:ok, branches} | {:error, error}`**: a database can fail where an ETS table cannot,
  and a row that no longer decodes must not be silently dropped.
- A state version number (`"version": 1`) is stored; a newer one is refused rather than guessed at.

## Consequences

- A resource that loses an attribute makes stored branches that mention it unloadable (`:storage`, naming the
  attribute) instead of dropping data.
- Relationships, calculations and aggregates loaded into a stored record are kept as terms; they can be large.
- `Ash.Type.Term` attributes and action input are stored as Erlang terms inside a base64 string or tagged structure,
  so the table is readable for ordinary data and opaque for exotic data.
- Metadata and action-input keys that are atoms only a not-yet-loaded host module mentions fail to load in a VM that has
  not loaded that module (development mode). String keys avoid this; releases load everything at boot.
