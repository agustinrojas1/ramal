---
name: ramal
description: "Use when a task touches Ramal (Ramal.branch, Ramal.run, Ramal.Resource, Ramal.propose) or when code must try changes to Ash application data without committing them: what-if runs, previews, dry runs, AI agents that explore alternatives, approvals."
---

# Working with Ramal

Ramal gives an Ash application Git-style branches of its data. A branch is a process holding an overlay: inside it,
your real Ash actions run (validations and policies included), reads see the database plus the branch's changes, and
writes stay in the branch until `Ramal.merge/2` replays them through the real actions. Read `usage-rules.md` of the
`ramal` dependency for the rules and gotchas; this file says how to approach a task.

## Decide first

- Is the code supposed to **try** something and let someone **decide**? Use a branch.
- Is it a real write the user asked for? Do not use a branch; call the Ash action.
- Is the actor an AI agent? It **proposes** (`Ramal.propose/2`); a person approves (`Ramal.approve/2`). Never give an
  agent `Ramal.merge/2`.

## Workflow

1. **Check the setup** in the host app: `extensions: [Ramal.Resource]` on each resource a branch should see, and
   `{Ramal.Supervisor, ...}` in the supervision tree. If either is missing, add it before writing branch code.
2. **Open** `{:ok, branch} = Ramal.branch(MyApp.Domain, name: "...", owner: user_or_session_id)`.
3. **Work inside** `Ramal.run(branch, fn -> ... end)` using the app's own actions. Never `Repo.insert` or raw SQL there.
4. **Look**: `Ramal.diff(branch)` for the rows changed, `Ramal.aggregate(...)` for exact counts and sums.
5. **Vary**: `Ramal.fork(branch)` to try an alternative; `Ramal.discard/1` the ones you drop. A fork made with
   `nested: true` is a branch of the branch that merges into it, not into the database.
6. **Hand over**: `Ramal.propose(branch, proposed_by: ..., reason: "...")`, then show the diff to the decider.
7. **Apply**: `Ramal.approve(branch, decided_by: person, actor: person)` merges through the real actions; handle
   `{:error, %Ramal.Error{reason: :stale}}` by re-running the work in a new branch.

## For an AI agent running inside the app

- Give it the branch tools: `Ramal.Tools.definitions(domain: ..., owner: ..., proposed_by: ...)` and
  `Ramal.Tools.call/3`. They cover open, list, fork, diff, propose and discard, and nothing that applies a change.
- Run its data tools in the branch: `Ramal.run(branch_id, fn -> ... end)` around each call, or `context:
  Ramal.context(branch_id)` on the Ash call where you cannot wrap it (an MCP server). `context:` does not hold back
  notifications.
- The full wiring, including an `AshAi` MCP plug, is in `docs/agents.md` of the `ramal` dependency.

## Tests

Start `Ramal.Supervisor` with `start_supervised!/1`. Assert that the database did not change inside the branch, that the
diff is what you expect, and that the database changed after the merge. Fork one branch instead of building two.

## Do not

- Write to the database inside a branch, or call `merge` from agent code.
- Nest `Ramal.run/2`, or start a process other than a `Task` inside it without calling `Ramal.run/2` there.
- Build a changeset or form outside `Ramal.run/2` and submit it inside (or the reverse): it fails with `:branch_mismatch`.
- Use an upsert with an `upsert_condition`; it is refused. Bulk actions work, record by record; a bulk update or destroy of a query needs `strategy: [:atomic, :stream]`. Keys the database generates are placeholders until the merge: do not store one outside an action input.
- Treat `owner:` as authorization. It filters `Ramal.list/2`; anyone with an id can act on the branch.
