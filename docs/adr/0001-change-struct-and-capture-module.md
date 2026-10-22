# 0001. `Ramal.Change` is the diff struct; the write-side hook is `Ramal.Capture`

Status: accepted, 2026-10-22. Issue: #2.

## Context

The documents used `Ramal.Change` for two things. `docs/DESIGN.md` sections 2, 5 and 8, the README and issues #2 and #6
use it for the struct that `diff/1` returns. The `CLAUDE.md` layout and issue #5 use it for the Ash change module that
captures creates, updates and destroys into the overlay. One module cannot be both a public data struct and an
`Ash.Resource.Change` implementation without being confusing, and the struct is public API the README already shows.

The overlay also needed a rule for what happens when a branch writes the same row twice, which the design left open
("the record is the full Ash struct as the action left it", nothing about combining).

## Decision

- `Ramal.Change` is the struct `%Ramal.Change{resource, key, kind, changes}`. The write-side Ash change is
  `Ramal.Capture`, `@moduledoc false`. `CLAUDE.md` and the design are updated to say so.
- The overlay records the **net effect on the base**, not the history (the log is the history). Creating a row and then
  deleting it leaves no entry. Deleting a base row and creating the same key again is an `:updated` entry. So a
  `:deleted` entry always means the base had the row, and `diff` can rely on that.
- `Ramal.Overlay.diff/3` is computed against base snapshots and returns changes sorted by ref, because a map has no
  write order. `Ramal.diff/1` reorders them by the log. A missing snapshot is `{:error, %Ramal.Error{reason:
  :missing_snapshot}}`, a new reason in the documented list.

## Consequences

- Nothing public is renamed: the README example stays valid.
- Issue #5 builds `Ramal.Capture`, not `Ramal.Change`.
- The overlay never polices duplicate keys or updates of missing rows. The write layer must reject them first, as the
  data layer would on the real base.
- A branch cannot tell "created then deleted" from "never touched" by looking at the overlay alone. The log still can.
