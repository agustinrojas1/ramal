# 0034. One tenant per branch

Status: accepted, 2026-10-23. Supersedes ADR 0009 for branches created with a tenant.

## Context

ADR 0009 refused every tenant inside a branch because the overlay is keyed by `{resource, primary key}`: with the
attribute strategy two tenants can hold the same key, and with the context strategy the same table name means different
tables. Supporting several tenants in one branch needs the tenant in every overlay key, base ref and codec entry. Hosts
that use multitenancy mostly work for one tenant at a time (a request, a job, an agent session), and the gap was the
one they hit first.

## Decision

- A branch works in at most one tenant, given at creation: `Ramal.branch(domain, tenant: tenant)`. It is stored with the
  branch and a fork keeps it. The overlay key and the base ref stay as they are: inside one branch the key is
  unambiguous.
- `Ramal.Resource.ensure_tenant/3` runs for every query and changeset on a multitenant resource that carries a tenant.
  The tenant must equal the branch's (compared with `Ash.ToTenant`, as the data layer sees it) or the call returns
  `:tenant_mismatch`. A branch without a tenant keeps ADR 0009's `:multitenancy_unsupported`, now saying to create it with
  `tenant:`. Resources that are not multitenant, and calls with no tenant, are not checked: a `global?` resource works
  without one.
- The loads Ramal makes for a read (calculations, relationship filters and sorts, aggregates) pass the query's tenant.
  The merge staleness read sets the branch's tenant on a multitenant resource that is not `global?`, and replay uses the
  tenant each log entry already records.

## Consequences

- A host serving several tenants opens one branch per tenant. A branch cannot compare or combine tenants.
- Storage keeps working: the tenant is one more key of the stored state, and a branch stored before it has none.
- A `global?` resource written with a tenant and read without one sees all tenants' rows, as outside a branch.
- Follow-up, 2026-10-23: an update or destroy whose record carries the tenant attribute of another tenant (attribute strategy) is refused with `:tenant_mismatch`. Ash finds no such row outside a branch, because the data layer filters by tenant; a branch has no data layer filter, so it compares the record's attribute with the call's tenant.
