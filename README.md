<p align="center">
  <img src="assets/logo/ramal-mark.svg" width="120" alt="Ramal">
</p>

<h1 align="center">Ramal</h1>

<p align="center"><b>Data branches as BEAM processes.</b></p>

> **Status: pre-alpha.** Nothing works yet. The design is in [docs/DESIGN.md](docs/DESIGN.md), the plan in [docs/ROADMAP.md](docs/ROADMAP.md). Until 0.1 ships, treat every API below as a sketch.

Ramal gives an [Ash](https://ash-hq.org) application Git-style branches of its data. A branch is a process holding an overlay over your database: fork it in microseconds, run thousands at once, let an agent or a person change things inside it, diff it, and merge it back through your own actions, with a human in the loop. No second database, no containers, no branch quota.

```elixir
{:ok, b} = Ramal.branch(MyApp.Farm, name: "move herd R7 to paddock L18")

Ramal.run(b, fn ->
  Ash.update!(herd, %{paddock_id: "L18"})                    # lands in the overlay, never in Postgres
  Ash.read!(MyApp.Farm.Herd, filter: [paddock_id: "L18"])   # sees it
end)

b2 = Ramal.fork(b)                                           # a second process, same base
Ramal.diff(b)        # [%Ramal.Change{resource: Herd, key: "R7", changes: %{paddock_id: {"L07", "L18"}}}]
Ramal.merge(b, actor: admin)                                 # replays the branch through the real actions
Ramal.discard(b2)
```

## Why

Agents, planners and people who evaluate what-if scenarios need many cheap alternate states of the same data. Database branching (Neon, Dolt) gives you a handful of slow branches; transactions give you one per connection and nothing that survives a request. A [2026 benchmark from Columbia's DAPLab](https://daplab.cs.columbia.edu/general/2026/05/26/branchable-databases-arent-ready-for-agentic-workloads.html) concluded that a system supporting "thousands of cheap alternate states without sacrificing normal query performance" does not exist yet.

On the BEAM a branch is a process with a map. That is the whole library.

## What it is not

- Not a database branch. No schema changes inside a branch, no branch-local indexes.
- Aggregates and calculations computed in the database do not see the overlay in 0.1.
- Meant for OLTP-sized working sets: the rows a session touches, not an analytics table.

## Install

Not on Hex yet. When it is:

```elixir
def deps do
  [{:ramal, "~> 0.1"}]
end
```

Requires Elixir 1.18+ and Ash 3.x. AshPostgres is optional and only needed for the Postgres storage backend.

## Name

*Ramal* is Spanish for a railway branch line: it leaves the main line, serves its own stations, and often rejoins it. Pronounced rah-MAHL.

## License

MIT. See [LICENSE](LICENSE).
