# 0009. Multitenancy is refused inside a branch

Status: accepted, 2026-10-22; for a branch that has a tenant superseded by ADR 0034. Follow-up to ADR 0007 (open question 6 in the design).

## Context

The overlay is keyed by `{resource, primary key}`. Tenants break that in two ways. With the attribute strategy two
tenants can hold rows with the same key, and a read for tenant A must not see tenant B's overlay rows. With the context
strategy (one schema per tenant) the same table name means different tables. The merge staleness read, which
fingerprints base rows by `{resource, key}`, also runs without a tenant (ADR 0007), so a tenanted resource failed at
merge time with an Ash error far from the cause.

Supporting tenants means a tenant in every overlay key, in the `base` refs, in the codec and in the staleness read. That
is a change to the data model, not a patch, and no host needs it yet.

## Decision

- **0.1 refuses a tenant instead of half supporting it.** Inside `Ramal.run/2`, a read or a write of a resource with a
  multitenancy strategy that carries a tenant returns `{:error, %Ramal.Error{reason: :multitenancy_unsupported}}`
  (the `ensure_untenanted/2` check, called by `Ramal.Preparation` and `Ramal.Capture`). The message says to use
  the resource without a tenant or outside the branch.
- A multitenant resource marked `global? true` still works without a tenant. Nothing changes outside a branch.
- The log still records `tenant` per entry, and merge still passes it to the replayed action; with the refusal the value
  is always `nil` for new branches. It stays so that adding support later does not change the log format.

## Consequences

- A host with tenanted resources can branch the other resources of its domain, and gets an early, named error on the
  tenanted ones.
- Supporting tenants later is a new ADR and a storage `version` bump: the tenant joins the overlay key and the base ref.
