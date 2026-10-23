# 0022. The stored state is compact (version 2)

Status: accepted, 2026-10-23. Changes the format of [ADR 0008](0008-postgres-storage.md); the rest of that decision stands.

## Context

A branch of 1,000 updated rows and 200 created ones was 3 MB of JSON, and 14 MB at 5,000 updates. Every `DateTime`
was a `$s` object with all its fields, every record repeated the `__meta__` and `__metadata__` of its resource, and
the snapshot of an updated row repeated the attributes the update did not change. The state is written on every
change of a branch, so its size is the cost of each write and of each reload.

## Decision

- **Version 2** writes `DateTime` (UTC, ISO calendar), `NaiveDateTime`, `Date` and `Time` as ISO 8601 text (`$dt`,
  `$ndt`, `$d`, `$tm`); any other value of those structs stays a `$s` struct. A `$s` struct lists only the fields that
  differ from its module's default struct, and `unterm/1` starts from that struct.
- **Shared extras:** the non-attribute fields that more than one record has are written once under `"extras"` and the
  records refer to them with `{"$x": index}`. A plain object never has a key that starts with `$`.
- **Snapshots against the overlay:** a base row's snapshot is stored as what differs from the branch's record of the
  same row (`"like": "overlay"`). A snapshot with no record to compare with (a deleted row) is stored whole.
- Version 1 is still read. A version 2 state is refused by a node that only reads version 1, so every node that shares
  the table is upgraded before any of them writes.

## Consequences

- The JSON is about a third of the size (`mix bench.memory`): 3,018,251 to 1,023,133 bytes at 1,000 updates.
- The decoded branch is equal to the encoded one (the codec's round-trip tests and a property of the dates).
- `Ramal.list/2`'s `owner:` filter compares the owner in its version 2 form. A branch stored in version 1 whose owner is
  a struct (or a date) has another form until it is written again, so the filter can miss it; `Ramal.list/2` checks
  the decoded owner, so it can never return another owner's branch. Ids and strings, the usual owners, are the same
  in both versions.
