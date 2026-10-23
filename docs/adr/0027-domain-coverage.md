# 0027. A domain a branch cannot cover is refused

Status: accepted, 2026-10-23. Amends [ADR 0003](0003-branch-process-lifecycle.md). Issue #107.

## Context

`Ramal.branch/2` required that at least one resource of the domain uses `Ramal.Resource`. A write inside a branch to
any other resource of the domain, directly or from a hook or a managed relationship, reached the database with no error
and no telemetry, which contradicts "nothing reaches the database before approval".

## Decision

`Ramal.branch/2` returns `:unbranchable_resources`, with the resources in `details.resources`, when the domain has a
resource that has a create, update or destroy action and neither uses `Ramal.Resource` nor opts out of it. Opting out is
`ramal do branchable? false end` on a resource that uses the extension: it is explicit, and writes to that resource are
real. A resource with no write action cannot be written, so it needs neither.

## Consequences

- A domain with an unrelated resource (a user table, an audit log) has to add the extension or opt out. That is the
  point: the host decides, in the resource, that its writes are real.
- A resource outside the domain, or written through another domain, is still not covered; the check sees one domain.
- No compile-time verifier in this change; the check is at `branch/2`.
