# Rules for working with Ramal

Ramal gives an Ash application Git-style branches of its data. A branch is a process holding an overlay: inside it,
reads see the database plus the branch's changes, and writes land in the overlay and never in the database until
`Ramal.merge/2`. Use it when code (an AI agent, a planner, a preview) must try a change on real data and a person or a
test decides whether it happens.

## Set up

- Add `extensions: [Ramal.Resource]` to every resource a branch must see or change. A resource without it is read and
  written for real, also inside a branch.
- Add `{Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}` to the supervision tree
  (`mix ramal.gen.migration` writes the table). Without `storage:` branches live in ETS and are lost on restart.
- In tests, `start_supervised!(Ramal.Supervisor)` before the first `Ramal.branch/2`.
- Mark credential and token resources `ramal do branchable? false end`.

## The calls

```elixir
{:ok, branch} = Ramal.branch(MyApp.Farm, name: "move R7", owner: user.id)

# Your real actions, validations and policies, in the branch. The database is not written.
{:ok, herds} =
  Ramal.run(branch, fn ->
    Ash.update!(herd, %{paddock_id: paddock.id}, actor: user)
    Ash.read!(MyApp.Farm.Herd, actor: user)
  end)

{:ok, copy}    = Ramal.fork(branch)                    # a second branch that starts where this one is
{:ok, changes} = Ramal.diff(branch)                    # [%Ramal.Change{kind: :updated, changes: %{attr: {before, after}}}]
{:ok, total}   = Ramal.run(branch, fn -> Ramal.aggregate!(MyApp.Farm.Herd, :sum, :head) end)
{:ok, _}       = Ramal.propose(branch, proposed_by: agent_id, reason: "R7 crowds L07")   # freezes it
{:ok, result}  = Ramal.approve(branch, decided_by: manager.id, actor: manager)           # merges; or Ramal.reject/2
:ok            = Ramal.discard(copy)
```

- Every function that takes a branch also takes its id. Keep the id, not the struct, between requests.
- `Ramal.run/2` returns `{:ok, result}`; `run!/2` returns the result and raises.
- `Ramal.merge/2` replays the log through the real actions in one transaction, with `authorize?: true`. Pass `actor:`.
- `Ramal.list(domain, status: :proposed, owner: id)` is what a reviewer lists.

## Rules

- Never write to the database from inside `run/2`, for example with `Repo.insert`. Only Ash actions on a resource with
  `Ramal.Resource` are captured.
- One topic per branch. Fork to try a variation; discard what you will not propose.
- Read the diff (`Ramal.diff/1`) before you propose or merge, and show it to the person who decides.
- An agent should `propose`, not `merge`. Ramal records who proposed and who decided; it does not check who may decide,
  so put that check in your own code.
- Pass `owner:` when opening a branch for a user or an agent session, and scope ids to them in your code. `owner` filters
  `list/2`; it is not authorization, and anyone holding an id can act on the branch.
- Use `Ramal.aggregate/4` for counts and sums inside a branch. Aggregates and calculations declared on the resource and
  computed in SQL do not see the overlay.
- Use `Ramal.load/3` (not `Ash.load/3`) to load a relationship onto a record the branch changed: `Ash.load/3` reselects the
  foreign key from the database, so it follows the old one. A load inside a read (`Ash.Query.load/2`) is patched.
- Use UUID primary keys. A resource whose key the database generates cannot be created inside a branch.
- An agent's tools run in a branch with `Ramal.run(branch_id, fn -> ... end)` around the call, or, where the call cannot
  be wrapped (an MCP server), with `context: Ramal.context(branch_id)` on the Ash call. `Ramal.Tools` has the branch
  tools themselves (open, list, fork, diff, propose, discard) and leaves out merge, approve and reject on purpose.

## Gotchas

- **`run/2` does not nest.** `run/2` inside `run/2` returns `{:error, %Ramal.Error{reason: :nested_branch}}`. For a branch
  of a branch, fork with `Ramal.fork(branch, nested: true)` and run each on its own; merging the fork replays what it
  wrote into its parent (`:stale` if the parent changed a row the fork read, `:parent_not_open` if the parent was merged or
  discarded, so discard the fork then). A `Task` started inside the function is in the branch too (`Task.async`,
  `Task.async_stream`, `Task.Supervisor`, and the tasks Ash starts). A process started any other way (`spawn`, a
  message to a GenServer) is not: call `run/2` inside it.
- **Build and run a changeset in the same place.** A changeset or form built outside `run/2` and submitted inside it, or
  the other way round, fails with `:branch_mismatch`. A query prepared outside `run/2` and read
  inside it is patched.
- **Every resource of the domain must use `Ramal.Resource` or opt out** with `ramal do branchable? false end`, or
  `Ramal.branch/2` returns `:unbranchable_resources`. A resource that opts out is written for real, from a branch too.
- **Merge refuses a stale branch.** If a row the branch read changed in the database, `merge/2` returns
  `{:error, %Ramal.Error{reason: :stale, details: %{rows: rows}}}` and writes nothing. Re-do the work in a new branch, or
  pass `on_stale: :ignore` when you know better. A fork shares its parent's base, so merging one makes its siblings stale.
- **Bulk actions are refused** inside a branch (`:bulk_unsupported`). Loop over single-row actions instead.
- **Upserts work** when the action has `upsert? true` or `upsert?: true` goes to `Ash.Changeset.for_create/4`: the row is
  looked up in the branch's view and updated or created. An `upsert_condition` is refused (`:upsert_unsupported`), and
  `upsert?: true` passed only to `Ash.create/2` acts as a plain create.
- **A branch works in one tenant**: `Ramal.branch(domain, tenant: tenant)`. A multitenant resource used with another tenant is refused, and so is any tenant in a branch that has none.
- **`type: :append_and_remove` with a link to remove** in `manage_relationship` is refused as a bulk action. Use
  `:append` and `:remove` in two calls.
- **A data layer that cannot roll back** (`Ash.DataLayer.Ets`) keeps the writes of a replay that failed halfway: the
  staleness check runs first, but a later `:merge_failed` lists `details.not_rolled_back`. Use Postgres where it matters.
- **Notifications are dropped** for writes in a branch unless the resource has `ramal do notify_in_branch? true end`. They
  are not dropped when you use `Ramal.context/1`.
- **Two processes writing one row of a branch**: while the first one's action runs, the second gets `:row_busy`; retry
  once it ends. A merge or a proposal waits for running actions (up to four seconds), and a fork leaves their writes out.
- **A proposed branch is frozen.** It refuses reads, writes and forks (`:not_open`); `diff/1` still works.
- **Writes since the last save are lost** if the node crashes. A branch is saved on create, propose, discard, unload and
  shutdown, not on every write.
- **Errors are values.** Match on `{:error, %Ramal.Error{reason: reason}}`. Inside an Ash action the error arrives in the
  `errors` of an `Ash.Error.Invalid`; `Ramal.Error.find/1` pulls it out.

## Testing

- Open a branch, act inside `Ramal.run/2`, assert on `Ramal.diff/1` and on a read outside the branch (the database did
  not change), then `Ramal.merge/2` and assert the database did.
- A test that needs two alternatives forks one branch instead of building two.

## More

- [README](https://github.com/agustinrojas1/ramal#readme), [design](https://github.com/agustinrojas1/ramal/blob/main/docs/DESIGN.md),
  [security notes](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md), and for agents the
  [agent guide](https://github.com/agustinrojas1/ramal/blob/main/docs/agents.md).
