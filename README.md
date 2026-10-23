<p align="center">
  <img src="https://raw.githubusercontent.com/agustinrojas1/ramal/main/assets/logo/ramal-mark-dark.svg" width="120" alt="Ramal">
</p>

<h1 align="center">Ramal</h1>

<p align="center"><b>Git-style branches for your Ash application's data, as BEAM processes.</b><br>Fork it, change it, diff it, merge it back, or throw it away. Nothing touches your database until you say so.</p>

[![Hex.pm](https://img.shields.io/hexpm/v/ramal.svg)](https://hex.pm/packages/ramal) [![HexDocs](https://img.shields.io/badge/hexdocs-ramal-blue.svg)](https://hexdocs.pm/ramal) [![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fagustinrojas1%2Framal%2Fmain%2Fdemo%2Framal_tour.livemd)

> **Status: 0.6, on [Hex](https://hex.pm/packages/ramal).** Branches, diff, merge, proposals, reads that agree with the branch (pages, aggregates, calculations), one tenant per branch, the LiveView inspector and the tools for AI agents work and are tested on Postgres. The branch lifecycle is [model-checked and its data rules are proved](#formally-verified). The API may still change before 1.0.

## What it does

Ramal lets an [Ash](https://ash-hq.org) application try something on its real data without doing it.

You open a **branch**. Inside the branch your own code runs unchanged: the same Ash actions, the same validations and
policies, the same reads. But every write lands in a small overlay held by a process instead of in Postgres, and every
read sees your database **plus** what the branch changed. When you are done you can look at exactly what changed
(`diff`), copy the branch to explore a variation (`fork`), apply it for real (`merge`), or drop it (`discard`).

```
              ┌─ branch A: move herd R7 to paddock L18 ─┐
              │                                          │
 Postgres ────┼─ branch B: move herd R7 to paddock L03 ──┼──▶  diff ──▶ merge one (through your real actions)
 (untouched)  │                                          │              the others are now stale and refuse
              └─ branch C: split herd R7 in two ─────────┘
```

A branch is one Erlang process and one map. There is no second database, no copied tables, no container and no branch
quota, so a program can open as many alternatives as it needs.

```elixir
{:ok, branch} = Ramal.branch(MyApp.Farm, name: "move herd R7 to paddock L18")

Ramal.run!(branch, fn ->
  # Your real action, validations and policies included. The row lands in the branch, never in Postgres.
  Ash.update!(herd, %{paddock_id: paddock.id})
  # A read inside the branch sees the base rows plus what the branch changed.
  Ash.read!(MyApp.Farm.Herd)
end)

{:ok, copy}    = Ramal.fork(branch)                  # a second branch that starts where this one is
{:ok, changes} = Ramal.diff(branch)                  # a list of %Ramal.Change{}, computed without querying the database
{:ok, merged}  = Ramal.merge(branch, actor: admin)   # replays the branch through the real actions, in one transaction
:ok            = Ramal.discard(copy)
```

## Why it exists

Agents, planners and people who ask "what if?" need many cheap, alternate states of the same data. The usual tools each
give you only part of that:

- **A transaction** is one alternate state, tied to one connection, gone when the request ends.
- **A copy of the database** (or a branching database) is a real second state, but expensive to create and to keep many of.
  In a [2026 study from Columbia's DAPLab](https://daplab.cs.columbia.edu/general/2026/05/26/branchable-databases-arent-ready-for-agentic-workloads.html),
  Neon ran into its cap on active branches, and Dolt created branches cheaply but read and joined slowly inside them. The
  authors conclude that agents "need databases that can support thousands of cheap alternate realities without giving up
  normal query performance", and add: "That system does not exist yet."
- **Your own draft tables** mean building and maintaining a second copy of your domain logic.

On the BEAM a branch can be a process with a map, and Ash already gives you actions, validations and policies to replay.
That combination is the whole library.

## What you can build with it

- **AI agents that explore alternatives.** Give an agent a branch instead of your database. It can try five plans,
  read the results of each, score them, keep the best and throw the rest away, and it cannot damage real data while it
  does. A tree search that forks promising states is exactly what a branch is cheap at (see the [benchmark](#benchmark)).
  [How to wire an agent to Ramal](#for-ai-agents).
- **What-if planning.** "What happens to pasture capacity if we move this herd?" Run the real move in a branch, read
  the numbers (`Ramal.aggregate/4` gives exact counts and sums for the branch), and discard it if you do not like the answer.
- **Preview and staging of edits.** Show a user the result of a change before it exists: the form edits a branch, the page
  renders the branch's reads and the diff, and "Save" merges.
- **Approvals and review.** An agent or a junior user proposes a change with `Ramal.propose/2`; a reviewer reads the diff
  and approves (which merges) or rejects. The proposer, the decider and the reasons are recorded on the branch.
- **Safe dry runs.** Run a series of record-level actions in a branch and read the diff to see what they would do, then
  merge or discard.
- **Several drafts at once.** A user keeps three versions of a plan open and compares them; each is its own branch and
  survives restarts when you use the Postgres storage.

## How it works, in four lines

1. **A branch is an overlay.** It holds the rows it created, updated or deleted, keyed by resource and primary key, plus a log of the writes.
2. **Reads are patched.** A Spark extension adds a preparation to your read actions: Postgres answers as usual, and the
   branch's overlay is applied on top (deleted rows dropped, changed rows replaced, new rows added if they match the query's filter, then sorted and paged).
3. **Writes are captured.** The extension adds a change to your create, update and destroy actions that, inside a branch,
   puts the result in the overlay instead of calling the data layer. Ash does all its normal work first.
4. **Merge replays through your actions.** The log is replayed through the real actions, in one transaction, after checking
   that no row the branch saw has changed in the database since. A branch that is no longer valid fails as a whole and leaves the database untouched.

Both hooks do nothing when no branch is active, and a test per hook proves it. The full design is in
[docs/DESIGN.md](https://github.com/agustinrojas1/ramal/blob/main/docs/DESIGN.md).

## Formally verified

Merging is the step that must never be wrong, so the rules behind it are checked by machine, not only by tests.
[`verification/`](https://github.com/agustinrojas1/ramal/tree/main/verification) holds two models:

- **A TLA+ model of the branch lifecycle**, checked with TLC over about 5.5 million states: writes, reads, fork, propose,
  approve, discard, merge, idle unload, killed processes and node restarts, interleaved the way the BEAM interleaves them.
  It proves that a merge commits at most once, that a merge never takes the write of an action that failed, and that what
  reads see is what the merge writes.
- **Proofs in Bend 2** (rechecked by a Lean-proved kernel) that a read in a branch is the base plus the overlay, that a
  merge loses no edit made outside the branch, and that an overlay entry never lies about the base.

The model found three real bugs that tests had missed, now fixed and covered by tests that failed before:
writes of a still-running action taken by a merge or fork ([ADR 0033](https://github.com/agustinrojas1/ramal/blob/main/docs/adr/0033-running-actions-hold-their-writes.md)),
and a branch merged twice when the merging process died after the commit ([ADR 0035](https://github.com/agustinrojas1/ramal/blob/main/docs/adr/0035-merged-status-in-the-merge-transaction.md)).
A conformance test ties the Bend model to `Ramal.Overlay`, and CI runs both checks. The
[verification README](https://github.com/agustinrojas1/ramal/blob/main/verification/README.md) says what is proved, what is assumed and what is not covered (filters and sorts of a patched read, for one, are covered by property tests instead).

## Quickstart

Ramal is on [Hex](https://hex.pm/packages/ramal), with docs on [HexDocs](https://hexdocs.pm/ramal). Add it to `mix.exs`:

```elixir
def deps do
  [{:ramal, "~> 0.6.0"}]
end
```

Requires Elixir 1.18+ and Ash 3.x. AshPostgres is optional and only needed for the Postgres storage backend.

**1. Add the extension to each resource a branch should see.**

```elixir
defmodule MyApp.Farm.Herd do
  use Ash.Resource,
    domain: MyApp.Farm,
    data_layer: AshPostgres.DataLayer,
    extensions: [Ramal.Resource]

  # ...
end
```

**2. Add the supervisor to your tree.**

```elixir
children = [
  MyApp.Repo,
  {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}
]
```

Run `mix ramal.gen.migration` for the `ramal_branches` table (run it again after upgrading from 0.3.0 for the owner column, then migrate). Without `storage:` branches live in ETS and are lost when
the supervisor stops, which is fine for development and tests.

**3. Branch.**

```elixir
{:ok, branch} = Ramal.branch(MyApp.Farm, name: "what if")

Ramal.run!(branch, fn ->
  Ash.create!(MyApp.Farm.Herd, %{name: "R10", head: 5})
end)

{:ok, [change]} = Ramal.diff(branch)
change.kind      #=> :created
change.changes   #=> %{name: {nil, "R10"}, head: {nil, 5}, ...}

Ash.read!(MyApp.Farm.Herd)       # outside the branch: no R10
Ramal.merge(branch)              # now R10 is in Postgres, created by your real create action
```

Every function that takes a branch also takes its id, and starts the branch process from storage if it is not running,
so a request can keep only the id.

## Try it

A guided tour opens branches of a small farm in Postgres, diffs and forks them, merges one, gets a stale one refused, and
shows a merge that fails halfway and leaves the database untouched. It needs a Postgres (`docker compose -f demo/docker-compose.yml up -d`
starts one) and comes in two forms:

- **In Livebook:** click the badge above, or open [`demo/ramal_tour.livemd`](https://github.com/agustinrojas1/ramal/blob/main/demo/ramal_tour.livemd).
  One section per chapter, with the explanation next to the cell you run.
- **In a terminal:** `elixir demo/walkthrough.exs`, which needs Elixir 1.18+.

[`demo/`](https://github.com/agustinrojas1/ramal/tree/main/demo) has what each chapter shows, and the browser view.

## A closer look

### Merging safely

`merge/2` records a fingerprint of every database row the branch reads or writes. At merge time it checks them again
inside the transaction. By default (`on_stale: :error`) it refuses when one has changed or disappeared, and it fails as a
whole, leaving the database untouched, if any replayed action is no longer valid:

```elixir
{:ok, a} = Ramal.branch(MyApp.Farm)
{:ok, b} = Ramal.fork(a)           # both started from the same farm

# ... each moves herd R7 to a different paddock inside its own branch ...

{:ok, _} = Ramal.merge(a)
{:error, %Ramal.Error{reason: :stale}} = Ramal.merge(b)   # R7 is no longer where b read it
```

Pass `on_stale: :ignore`, or a function that decides per stale row, when you know better.

### Proposals: an agent proposes, a person decides

```elixir
{:ok, branch} = Ramal.branch(MyApp.Farm)
Ramal.run!(branch, fn -> Ash.update!(herd, %{paddock_id: paddock.id}, authorize?: false) end)
{:ok, _proposed} = Ramal.propose(branch, proposed_by: agent, reason: "R7 is crowding L07")

{:ok, pending} = Ramal.list(MyApp.Farm, status: :proposed)   # what a reviewer sees
{:ok, changes} = Ramal.diff(branch)                          # what the reviewer reads
{:ok, result}  = Ramal.approve(branch, decided_by: manager, actor: manager)   # merges; or Ramal.reject(branch, ...)
```

A proposed branch is frozen: it refuses further writes, so the diff the reviewer reads is the diff that gets merged.
Ramal records who proposed and who decided, and leaves the question of *who may decide* to your own policies.

### Exact numbers for a branch

`Ramal.aggregate/4` takes the database's answer for the rows the branch did not touch and adds the rows it did, so it
costs what the overlay holds, not what the table holds.

```elixir
Ramal.run!(branch, fn ->
  Ash.create!(MyApp.Farm.Herd, %{name: "R10", head: 5})
  Ramal.aggregate!(MyApp.Farm.Herd, :sum, :head)   # the base total plus 5
end)
```

It supports `:count`, `:exists`, `:sum`, `:min`, `:max`, `:avg`, `:first` and `:list`. The last two follow the query's sort and accept `uniq?:` and `include_nil?:`.

### Per-tenant branches

A branch of a multitenant application works in one tenant: `Ramal.branch(MyApp.Farm, tenant: "acme")`. Reads and writes
inside it must carry that tenant (`:tenant_mismatch` otherwise), other tenants' rows never enter its overlay, and the
merge checks and replays in the tenant. Both the attribute and the schema-per-tenant strategies work.

### Per-user branches

Pass `owner:` to `Ramal.branch/2` and `Ramal.list(domain, owner: user_id)` shows each user their own. It is a filter, not
access control; the [security notes](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md) say where the line is.

### For AI agents

Ramal is written with an agent in the loop in mind: the agent works in a branch, a person approves. Three pieces:

- **`Ramal.Tools`** gives an agent the branch calls (open, list, fork, diff, propose, discard) as tool definitions with
  JSON Schemas and one `call/3`, for any tool loop or MCP server. There is deliberately no merge or approve tool: an
  agent proposes, a person decides. The host fixes the domain and owner, so the agent cannot reach another user's branch.
- **`Ramal.context/1`** is the `context:` option that runs an Ash call in a branch, for tool servers (such as
  [AshAi](https://hexdocs.pm/ash_ai)) that cannot wrap the call in `Ramal.run/2`.
- **`usage-rules.md` and a skill** teach coding agents (Claude Code, Cursor, Copilot) to use Ramal correctly. They are in
  the format of [`usage_rules`](https://hex.pm/packages/usage_rules): `mix usage_rules.sync` puts them in your `AGENTS.md`
  and `.claude/skills`.

```elixir
opts = [domain: MyApp.Farm, owner: "session-42", proposed_by: "planner agent"]

tools = Ramal.Tools.definitions(opts)                      # name, description, input_schema: hand these to your model
{:ok, %{"id" => id}} = Ramal.Tools.call("ramal_open_branch", %{"name" => "move R7"}, opts)
{:ok, %{"changes" => _}} = Ramal.Tools.call("ramal_branch_diff", %{"branch_id" => id}, opts)
```

The [agent guide](https://github.com/agustinrojas1/ramal/blob/main/docs/agents.md) has the tool loop, the `AshAi` MCP plug
and what is and is not tested.

## Key features

- **Real actions inside a branch.** Validations, policies, hooks, defaults and managed relationships run as they do outside.
- **Fork, diff, merge, discard** as ordinary function calls, plus **proposals** with a recorded proposer and decider.
- **Persistent.** With `Ramal.Storage.Postgres` a branch is saved when it is created, proposed, discarded, unloaded or when the supervisor shuts down, so it survives restarts; idle branches unload from memory and come back on demand.
- **Staleness detection** at merge, with a choice of what to do about it.
- **Exact aggregates** for a branch without scanning the table, and loaded, filtered and sorted aggregates that agree with the branch.
- **Pages, prepared queries and module calculations** that see the branch.
- **One tenant per branch**, on both multitenancy strategies.
- **Formally verified lifecycle and data rules** ([above](#formally-verified)).
- **Many-to-many** links changed in a branch are seen by `many_to_many` loads and by `manage_relationship`.
- **Telemetry** for every branch lifecycle step, every patched read and every captured write.
- **Safety valves.** Optional per-domain limits on open branches and on the rate of new ones, a heap limit on each branch
  process, and the `sensitive?` attributes of a stored actor are dropped from the saved branch.
- **Agent tooling.** Branch tools for an LLM agent without merge or approve, a context for MCP servers, and usage rules and a skill for coding agents ([above](#for-ai-agents)).
- **A LiveView inspector** in a separate package, [`ramal_live`](#inspector).
- **No Phoenix in core, AshPostgres optional.** The library adds one supervisor to your tree and nothing else.

## Honest limits

Ramal is deliberately small, and it says what it does not do:

- **Not a database branch.** No schema changes inside a branch, no branch-local indexes, and a branch lives on one node. `Ramal.run/2` cannot be nested.
- **Aggregates loaded inside a branch are recomputed from the branch's rows,** which reads the related rows of each
  returned row where the database would sum them in one query. `custom` aggregates (data-layer SQL),
  a join filter and a custom read action keep the database's value, and Ramal emits `[:ramal, :read, :unpatched_aggregate]` so a
  test can notice. A filter or sort on an aggregate sees the branch too, and when the branch changed a resource on its path
  that reads the aggregate for every row the rest of the filter matches. For one total over a large table,
  `Ramal.aggregate/4` is cheaper.
- **Use `Ramal.load/3` to load onto a record the branch changed.** `Ash.load/3` reselects the foreign key from the
  database without running any hook, so after a herd moved paddock in the branch it still follows the old one. A load
  inside a read (`Ash.Query.load/2`) is patched.
- **A filter or sort through a relationship the branch changed can read more.** Ramal checks that part of the filter in
  memory on the rows the database returns for the rest, so keep attribute predicates next to it to narrow the read. A
  filter through one `belongs_to` or `has_one` is narrowed in the database too, except under `not`; `exists`, longer
  paths and `has_many` paths read every row the rest of the filter allows.
- **Text sorts inside a branch use byte order,** not the database's collation, once the branch has changed that resource:
  `Banana` sorts before `apple`. Numbers, dates and keys sort exactly.
- **Every resource of the domain is covered or opts out.** `Ramal.branch/2` refuses a domain with a resource that has
  write actions and neither uses `Ramal.Resource` nor sets `branchable? false`; a resource that opts out is written for
  real, from a branch too. Only the branch's domain is checked: a resource of another domain works in the branch if it uses `Ramal.Resource`, and is written for real if it does not. Build a changeset in the same `Ramal.run/2` that runs it. A query prepared outside a branch and read inside it is patched.
- **Resources whose primary key the database generates cannot be created** in a branch (use UUIDs), and
  notifications are dropped unless a resource opts in with `notify_in_branch? true`.
- **Upserts work, with two exceptions.** An upsert looks its row up in the branch's view, so it updates a base row, a row
  the branch created, or creates one. An `upsert_condition` is refused (`:upsert_unsupported`), and `upsert?: true` given
  only to `Ash.create/2` at call time cannot be seen and acts as a create: set it on the action or pass it to
  `Ash.Changeset.for_create/4`.
- **A branch works in one tenant,** given at `Ramal.branch/2`.
- **Reads fetch candidate rows and patch them in memory.** That is cheap for the rows a session touches and wrong for an
  analytics table: Ramal is meant for OLTP-sized working sets.
- **Merge is slower than a SQL statement,** because it replays each change through your action. That is the price of
  merging through your own rules.
- **Writes since the last save are lost if the node crashes.** A branch is saved at the moments listed above, not on every write.
- **Bulk actions run record by record** inside a branch, each one captured like a single action, so they cost what a loop costs. A bulk update or destroy of a query must allow `strategy: [:atomic, :stream]`.
- **A `through` path of several hops stays unsupported:** it sees the base rows of its intermediate resources.
- **Authorization is yours.** Anyone who holds a branch id can act on it. Ramal records who decided and never checks.
- **Pre-1.0.** The public API may change before 1.0; the changelog says when it does.

The complete list, with the reasons, is in the [design document](https://github.com/agustinrojas1/ramal/blob/main/docs/DESIGN.md)
and the [ADRs](https://github.com/agustinrojas1/ramal/tree/main/docs/adr).

## Inspector

[`ramal_live`](https://github.com/agustinrojas1/ramal/tree/main/ramal_live) is a separate package with a LiveView page that shows the open and proposed branches as
columns, each with its diff as before and after rows, and buttons to fork, merge, discard, approve and reject. It is
mounted by your router inside your own `live_session`, so it uses your LiveView socket and JavaScript, and has no asset
pipeline. Ramal itself never depends on it.

```elixir
ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
```

![The Ramal inspector with four open branches, each moving herd R7 to a different paddock, shown as columns of before and after rows](https://raw.githubusercontent.com/agustinrojas1/ramal/main/assets/inspector.png)

To see it move before wiring it into an app, run the demo from a clone of the repository: `docker compose up -d db`, then
`elixir ramal_live/examples/farm_demo.exs`. It starts a seeded farm where one button opens four branches that each move
a herd to a different paddock, and merging one makes the others stale. The
[ramal_live README](https://github.com/agustinrojas1/ramal/blob/main/ramal_live/README.md) has the steps and the setup, and
[ADR 0015](https://github.com/agustinrojas1/ramal/blob/main/docs/adr/0015-inspector-mounting.md) explains why it is built this way.

## Benchmark

[`bench/`](https://github.com/agustinrojas1/ramal/tree/main/bench) is a separate project that runs the same work against Ramal and two plain-Postgres baselines (one table copied per fork, one shared delta table) on 20,000 rows. In the run of 2026-10-23 on Ramal 0.6.1 published in [`bench/README.md`](https://github.com/agustinrojas1/ramal/blob/main/bench/README.md), on one shared sandbox with the database on localhost (which moves by tens of percent between runs):

- **Fork** takes 0.05 ms against 31 ms for a table copy with an empty overlay, and 2.7 ms against 29 ms with 1,000 changes, because a fork copies a map.
- **A tree search** (20 forks, 100 updates, 20 scorings) takes 280 ms against 873 ms for table copies and 279 ms for the delta table.
- **Where it loses:** reading 2,000 rows inside a branch takes 9 to 18 ms (about 10 ms through Ash with no branch) against about 2 ms for raw SQL, `Ramal.aggregate/4` costs 8 ms with 100 changes and 32 ms with 1,000, and merging replays every change through your action at about 0.4 ms each, against one SQL statement for the baseline.

The figures are indicative. Run `mix bench` on your own hardware before drawing a conclusion; the file also says how it differs from the DAPLab study quoted above.

## Learn more

- [HexDocs](https://hexdocs.pm/ramal): the API, with an example on every function.
- [Agent guide](https://github.com/agustinrojas1/ramal/blob/main/docs/agents.md) and [usage rules](https://github.com/agustinrojas1/ramal/blob/main/usage-rules.md): Ramal for AI agents.
- [Design](https://github.com/agustinrojas1/ramal/blob/main/docs/DESIGN.md) and [roadmap](https://github.com/agustinrojas1/ramal/blob/main/docs/ROADMAP.md): how it works and what comes next.
- [Architecture decision records](https://github.com/agustinrojas1/ramal/tree/main/docs/adr): why each choice was made.
- [Security notes](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md): what Ramal enforces and what it leaves to you.
- [Changelog](https://github.com/agustinrojas1/ramal/blob/main/CHANGELOG.md) and [contributing](https://github.com/agustinrojas1/ramal/blob/main/CONTRIBUTING.md).

## Name

*Ramal* is Spanish for a railway branch line: it leaves the main line, serves its own stations, and often rejoins it. Pronounced rah-MAHL.

## License

MIT. See [LICENSE](https://github.com/agustinrojas1/ramal/blob/main/LICENSE).
