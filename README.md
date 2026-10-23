<p align="center">
  <img src="assets/logo/ramal-mark-dark.svg" width="120" alt="Ramal">
</p>

<h1 align="center">Ramal</h1>

<p align="center"><b>Data branches as BEAM processes.</b></p>

> **Status: 0.2, not on Hex yet.** Branches, diff, merge, proposals, exact aggregates and the LiveView inspector work and are tested on Postgres; the API may still change before 1.0. The design is in [docs/DESIGN.md](docs/DESIGN.md), the decisions in [docs/adr](https://github.com/agustinrojas1/ramal/tree/main/docs/adr), the plan in [docs/ROADMAP.md](docs/ROADMAP.md).

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

Count a state without reading the table: `Ramal.aggregate/4` takes the database's answer for the rows the branch did not
touch and adds the rows it did, so it costs what the overlay holds, not what the table holds.

```elixir
Ramal.run!(branch, fn ->
  Ash.create!(MyApp.Farm.Herd, %{name: "R10", head: 5})
  Ramal.aggregate!(MyApp.Farm.Herd, :sum, :head)   # the base total plus 5
end)
```

## Why

Agents, planners and people who evaluate what-if scenarios need many cheap alternate states of the same data. Transactions give you one per connection and nothing that survives a request. Branching databases trade one need for the other: in a [2026 study from Columbia's DAPLab](https://daplab.cs.columbia.edu/general/2026/05/26/branchable-databases-arent-ready-for-agentic-workloads.html), Neon ran into its cap on active branches, and Dolt created branches cheaply but read and joined slowly inside them. The authors conclude that agents "need databases that can support thousands of cheap alternate realities without giving up normal query performance", and add: "That system does not exist yet."

On the BEAM a branch is a process with a map. That is the whole library.

## What it is not

- Not a database branch. No schema changes inside a branch, no branch-local indexes.
- Aggregates and calculations computed in the database do not see the overlay (`[:ramal, :read, :unpatched_aggregate]` is emitted so tests can notice). `Ramal.aggregate/4` gives the exact count, sum, min, max, avg or exists for a branch: the database aggregates the rows the branch did not touch and the branch reads the ones it did, so the cost follows the size of the overlay, not of the table.
- Bulk actions and upserts are refused inside a branch, resources whose primary key the database generates cannot be created in one, and notifications are dropped unless a resource opts in with `notify_in_branch? true`.
- Meant for OLTP-sized working sets: the rows a session touches, not an analytics table.

## Install

Not on Hex yet. When it is:

```elixir
def deps do
  [{:ramal, "~> 0.2"}]
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

## Inspector

[`ramal_live/`](https://github.com/agustinrojas1/ramal/tree/main/ramal_live) is a separate package with a LiveView page that shows the open and proposed branches as
columns, each with its diff as before and after rows, and buttons to fork, merge, discard, approve and reject. It is
mounted by your router inside your own `live_session`, so it uses your LiveView socket and JavaScript, and has no asset
pipeline. Ramal itself never depends on it.

```elixir
ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
```

To see it move before wiring it into an app, `elixir ramal_live/examples/farm_demo.exs` starts a seeded farm where one button
opens four branches that each move a herd to a different paddock, and merging one makes the others stale. There is no
screenshot yet.

See the [ramal_live README](https://github.com/agustinrojas1/ramal/blob/main/ramal_live/README.md) for the setup and [ADR 0015](docs/adr/0015-inspector-mounting.md) for why it is built this way.

## Benchmark

[`bench/`](https://github.com/agustinrojas1/ramal/tree/main/bench) is a separate project that runs the same work against Ramal and two plain-Postgres baselines (one table copied per fork, one shared delta table) on 20,000 rows. In the run published in [`bench/README.md`](https://github.com/agustinrojas1/ramal/blob/main/bench/README.md), on one shared sandbox with the database on localhost:

- **Fork** takes 0.04 ms against 20 ms for a table copy, because a fork copies a map.
- **A tree search** (20 forks, 100 updates, 20 scorings) takes 183 ms against 586 ms for table copies and 172 ms for the delta table.
- **Where it loses:** reading 2,000 rows inside a branch takes about 10 ms against about 1 ms for raw SQL, and merging replays every change through your action at about 0.7 ms each, against one SQL statement for the baseline.

The figures are indicative. Run `mix bench` on your own hardware before drawing a conclusion; the file also says how it differs from the DAPLab study quoted above.

## Name

*Ramal* is Spanish for a railway branch line: it leaves the main line, serves its own stations, and often rejoins it. Pronounced rah-MAHL.

## License

MIT. See [LICENSE](https://github.com/agustinrojas1/ramal/blob/main/LICENSE).
