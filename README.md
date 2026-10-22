<p align="center">
  <img src="assets/logo/ramal-mark.svg" width="120" alt="Ramal">
</p>

<h1 align="center">Ramal</h1>

<p align="center"><b>Data branches as BEAM processes.</b></p>

> **Status: 0.1, not on Hex yet.** The core works and is tested on Postgres; the API may still change before 1.0. The design is in [docs/DESIGN.md](docs/DESIGN.md), the decisions in [docs/adr](https://github.com/agustinrojas1/ramal/tree/main/docs/adr), the plan in [docs/ROADMAP.md](docs/ROADMAP.md).

Ramal gives an [Ash](https://ash-hq.org) application Git-style branches of its data. A branch is a process holding an overlay over your database: fork it, let an agent or a person change things inside it, diff it, and merge it back through your own actions, with a human in the loop. No second database, no containers, no branch quota.

```elixir
{:ok, branch} = Ramal.branch(MyApp.Farm, name: "move herd R7 to paddock L18")

Ramal.run!(branch, fn ->
  # Runs the real action, validations and policies included. The row lands in the branch, never in Postgres.
  Ash.update!(herd, %{paddock_id: paddock.id})
  # A read inside the branch sees base rows plus what the branch changed.
  Ash.read!(MyApp.Farm.Herd)
end)

{:ok, copy} = Ramal.fork(branch)              # a second branch that starts where this one is
{:ok, changes} = Ramal.diff(branch)           # a list of %Ramal.Change{}, computed without querying the database
{:ok, merged} = Ramal.merge(branch, actor: admin)   # replays the branch through the real actions, in one transaction
:ok = Ramal.discard(copy)
```

`merge/2` refuses when a row the branch saw has changed in the database since (`on_stale: :error`, the default), and
fails as a whole, leaving the database untouched, when any replayed action is no longer valid.

When an agent proposes and a person decides, freeze the branch as a proposal instead of merging it. Ramal records who
proposed and who decided, and leaves the question of who may decide to your own policies:

```elixir
{:ok, branch} = Ramal.branch(MyApp.Farm)
Ramal.run!(branch, fn -> Ash.update!(herd, %{paddock_id: paddock.id}, authorize?: false) end)
{:ok, _proposed} = Ramal.propose(branch, proposed_by: agent, reason: "R7 is crowding L07")

{:ok, pending} = Ramal.list(MyApp.Farm, status: :proposed)   # what a reviewer sees
{:ok, changes} = Ramal.diff(branch)                          # what the reviewer reads
{:ok, result} = Ramal.approve(branch, decided_by: manager, actor: manager)   # merges; or Ramal.reject(branch, ...)
```

## Why

Agents, planners and people who evaluate what-if scenarios need many cheap alternate states of the same data. Transactions give you one per connection and nothing that survives a request. Branching databases trade one need for the other: in a [2026 study from Columbia's DAPLab](https://daplab.cs.columbia.edu/general/2026/05/26/branchable-databases-arent-ready-for-agentic-workloads.html), Neon ran into its cap on active branches, and Dolt created branches cheaply but read and joined slowly inside them. The authors conclude that agents "need databases that can support thousands of cheap alternate realities without giving up normal query performance", and add: "That system does not exist yet."

On the BEAM a branch is a process with a map. That is the whole library.

## What it is not

- Not a database branch. No schema changes inside a branch, no branch-local indexes.
- Aggregates and calculations computed in the database do not see the overlay (`[:ramal, :read, :unpatched_aggregate]` is emitted so tests can notice). `Ramal.aggregate/4` gives the exact count, sum, min, max, avg or exists for a branch by reading the patched rows, at the cost of reading them.
- Bulk actions and upserts are refused inside a branch, resources whose primary key the database generates cannot be created in one, and notifications are dropped unless a resource opts in with `notify_in_branch? true`.
- Meant for OLTP-sized working sets: the rows a session touches, not an analytics table.

## Install

Not on Hex yet. When it is:

```elixir
def deps do
  [{:ramal, "~> 0.1"}]
end
```

Requires Elixir 1.18+ and Ash 3.x. AshPostgres is optional and only needed for the Postgres storage backend.

Add the extension to each resource a branch should see, and the supervisor to your tree:

```elixir
use Ash.Resource, extensions: [Ramal.Resource], ...

children = [
  MyApp.Repo,
  {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}
]
```

`mix ramal.gen.migration` writes the migration for the `ramal_branches` table. Without `storage:` branches live in
ETS and are lost when the supervisor stops.

## Name

*Ramal* is Spanish for a railway branch line: it leaves the main line, serves its own stations, and often rejoins it. Pronounced rah-MAHL.

## License

MIT. See [LICENSE](https://github.com/agustinrojas1/ramal/blob/main/LICENSE).
