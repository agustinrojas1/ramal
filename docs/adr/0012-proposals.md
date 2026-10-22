# 0012. Proposals are a branch status and a field

Status: accepted, 2026-10-22. Issue: #24.

## Context

ROADMAP 0.2 sketched `Ramal.propose/2` as "a branch becomes a proposal record (`ramal_proposals`) that someone approves
(which merges) or rejects (which discards), with the diff and the staleness check stored at decision time". A proposal
has exactly one branch, and a branch has at most one proposal. The decision has to be recorded in the same step that
marks the branch merged, or a crash between the two leaves an approved proposal whose branch is still open.

## Decision

- **No new table, no new storage callbacks.** `Ramal.Branch` gets two statuses, `:proposed` and `:rejected`, and a
  `proposal` field: `%{proposer, reason, proposed_at, decision}` with `decision` `nil` or `%{status, by, reason, at,
  replayed, stale}`. `Ramal.Storage.Codec` stores it in the existing `state` document (written field by field, no new
  atoms, actors without their sensitive attributes as in ADR 0010); the `status` column gains two values. State version
  stays 1: a branch stored by 0.1.0 has no `"proposal"` key and loads with `nil`.
- **`propose/2`** freezes an open branch: `Server.propose/2` applies the change and persists before replying. A proposed
  branch is not open, so reads, writes, forks, merges and a second proposal return `:not_open`; `diff/1`, `get/1` and
  `list/2` keep working.
- **`approve/2`** is `Ramal.Merge.run` on a `:proposed` branch (the merge claim takes the status it expects). The
  decision, with the replay count and the stale rows the merge let through, is added by the same server call that marks
  the branch `:merged`, so the two cannot be separated. Failure leaves the branch `:proposed`.
- **`reject/2`** records the decision, sets `:rejected`, persists and stops the process. Overlay and log stay, because the
  rejected diff is the audit trail; `discard/1` does not apply to it.
- **Withdrawing** is `discard/1` on a proposed branch.
- **Authorization is the host's.** `:decided_by` is recorded, never checked. Ramal has no notion of a user, and a check
  callback would be a plugin point with no second use.
- **The diff is not copied.** A proposed, merged or rejected branch is frozen, so `diff/1` of the stored branch is the
  diff at decision time. (After a merge, `diff/1` compares against snapshots taken when the branch wrote, not against
  the base as merged.)

## Consequences

- Listing pending proposals is `list(domain, status: :proposed)`; there is no separate query, filter by proposer or
  pagination. A host that needs them reads the stored branches.
- A rejected branch keeps its overlay and log in storage until the host deletes the row; a discarded one does not.
- Two deciders racing: the merge claim and the process serialize them. The loser gets `:not_open`.
- "Several approvers" or "request changes" are not modelled. They would be a new ADR with a reason from a real host.
