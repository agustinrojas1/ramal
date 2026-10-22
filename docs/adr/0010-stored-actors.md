# 0010. Stored actors drop sensitive attributes

Status: accepted, 2026-10-22. Follow-up to ADR 0008 (open question 7 in the design).

## Context

A log entry keeps the actor it was recorded with, so that merge can replay it under the same policies. ADR 0008 stored
the actor as the term it is, which persists a whole user record, including a password hash or an API token, in the
`ramal_branches.state` column. The design's alternative, a host `Ramal.Actor` serializer, is a plugin point with one
use and a callback every host would have to write.

## Decision

- When the actor is an Ash resource record, attributes marked `sensitive?` are stored as `nil` (`Ramal.Storage.Codec`).
  Ash already has the flag for this purpose: it hides the value from `inspect` and logs. Ramal reuses it instead of
  inventing a second list.
- Any other actor (a map, a tuple, an id) is stored as it is. It is the host's own shape, and Ramal cannot know which
  of its fields are secret.
- No serializer callback and no option. A host that does not want any actor in its table passes `actor:` to
  `Ramal.merge/2`, which replaces every recorded actor.

## Consequences

- An actor loaded from storage has `nil` in its sensitive fields. A policy that reads one of them (checking a token,
  say) sees `nil` when a stored branch is merged without `actor:`. The policies Ramal has seen read roles and ids.
- Only attributes are covered. A loaded relationship or calculation on the actor is stored as a term, so a host that
  loads secrets that way should pass `actor:` at merge.
- A resource that has no `sensitive?` flags stores its actor whole, as before.
