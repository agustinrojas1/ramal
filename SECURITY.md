# Security policy

## Supported versions

Ramal is pre-1.0. Only the latest released version receives security fixes.

## Reporting a vulnerability

Do not open a public issue with the details. Email the maintainer, [@agustinrojas1](https://github.com/agustinrojas1), at the address on their GitHub profile. Include the Ramal, Ash and AshPostgres versions, the resource and action involved, and a failing test or the smallest call sequence that shows the problem.

If you cannot find an address, open an issue that says only that you have a security report and want a private channel, with no details, and the maintainer will reply there.

You can expect an acknowledgement within a week. A fix is released as a patch version, and the report is credited in `CHANGELOG.md` unless you ask otherwise.

## What counts

Ramal sits between your actions and your data layer, so the reports that matter most are:

- A write inside a branch that reaches the database before `Ramal.merge/2`.
- A read inside a branch that returns rows a policy or filter should have excluded, or a branch that sees another branch's changes.
- A merge that skips validations or policies that the real action would run.
- Branch storage (`Ramal.Storage.Postgres`) loading data that creates atoms or runs code.

## Security model and defaults

What Ramal does and does not protect, so you can decide what to add. Each point is covered by a test or cites the code.

**Trust boundary.** Ramal runs inside your VM and trusts the code around it, as any library does. It does not authenticate or authorize *who* may use a branch: knowing a branch id (a random UUID) is enough to `Ramal.get/1`, `diff/1`, `merge/2` or `discard/1` it, and `Ramal.list/2` lists every branch of a domain unless you pass `owner:`. An *owner* (below) filters what a user sees; it does not stop someone who holds an id. Scope branch ids to your users in your own code. What Ramal does enforce is that a merge replays each write through the real action with `authorize?: true` (the default), as the actor you pass or the one recorded.

**SQL.** `Ramal.Storage.Postgres` is the only module that writes SQL. The table name is a constant and every value, including branch names, metadata and ids, is a bound parameter; ids are dumped as UUIDs first, so anything else is `:not_found`. Everything else goes through Ash expressions with bound values (`Ramal.Aggregate`, `Ramal.Merge`).

**Atoms.** Nothing creates an atom from stored or client data except a module name that has a beam file on the code path, and the name must look like a module name (`Elixir.A.B`, no separators). Everything else uses `String.to_existing_atom/1`; the inspector maps client strings through a closed table.

**What is stored.** A stored branch (`ramal_branches.state`, or the ETS table) holds the overlay (whole records), the raw input of every captured write, and the actors. Sensitive attributes of an *actor record* are stored as `nil` (ADR 0010), but the input of a write that carries a password or token argument must be stored to replay, so a stored branch is as sensitive as the data it touches. Mark credential resources `ramal do branchable? false end`, restrict access to the table, and encrypt it at rest if your data needs it. `inspect/1` of a `Ramal.Branch` prints only its id, name, domain, status and creation time, so crash reports and log lines do not carry the log. Telemetry events and the inspector's PubSub messages carry ids, names of resources and actions, and never record data.

**Stored state is read defensively.** The `state` column is data, not code: a malformed or hostile value makes `Ramal.get/1` return `{:error, %Ramal.Error{reason: :storage}}` and never crashes the caller. Whoever can write that column can still change what a merge replays (the log and its actors), so give the table the same write protection as the tables it replays into.

**ETS.** `Ramal.Storage.ETS` and the supervisor's own table are `:public` named tables, because every branch process writes to them. Any code in the VM can read or write them; use `Ramal.Storage.Postgres` when branches must survive a restart, and treat the VM as the boundary.

**Dependencies.** CI runs `mix hex.audit` for the library, `bench/` and `ramal_live/` and fails on a retired package or a published advisory. Dependabot proposes updates.

### Per-user branches

Pass `owner:` to `Ramal.branch/2` (a fork keeps its parent's owner, or takes `owner:`) and `Ramal.list(domain, owner: user_id)` returns that user's branches only; without `owner:` it lists everything, as before. Ramal stores the owner with the branch and compares it with `==`, and nothing else reads it (ADR 0018).

- **Filter, not authorization.** `Ramal.get/1`, `diff/1`, `merge/2`, `discard/1` and `run/2` accept any id. If a user can send an id they did not get from `list/2`, check `branch.owner` yourself before calling them.
- **Use an id or a string as the owner.** It is stored in the branch's state as given and not redacted; a user record would store its password hash. `inspect/1` of a branch does not print it.
- **`owner: nil` lists unowned branches**, so do not pass a signed-out user's `nil` through: that shows every branch created without an owner. The inspector refuses when its `:owner` function returns `nil`.
- **Cost.** With Postgres the filter is applied in SQL on the state column, so other users' branches are not decoded; there is no index, so it scans the domain's rows like `status:` does.

### The branch tools for an LLM agent (`Ramal.Tools`)

What the tools send to the model's provider, and what the model can reach (ADR 0019).

- **Diffs are sent, with sensitive values redacted.** `ramal_branch_diff` returns the before and after value of every changed attribute to the model and so to its provider. Attributes marked `sensitive?: true` are returned as `[redacted]` (`Ramal.Change.redact/1`, the rule the inspector uses); every other value is sent as it is, so mark credentials `sensitive?` and keep them in resources with `branchable? false`.
- **Set `:owner`.** Without it the tools see every branch of the domain: the agent can fork, diff and propose any user's branch. With it, a branch of another owner is "not found", whatever id the model passes.
- **An agent cannot withdraw a proposal.** `ramal_discard_branch` refuses a `:proposed` branch, because a person is reviewing it. Merge, approve and reject are not tools.
- **Your own tools are yours to scope.** `Ramal.run/2` and `Ramal.context/1` accept any id, so a tool that takes a `branch_id` from the model, or an MCP plug that trusts a header, must check the owner first; the examples in `docs/agents.md` do.

### The inspector (`ramal_live`)

The inspector can merge, approve, reject, discard and fork any branch of its domain. It checks nothing itself.

- **Mount it behind your authorization**, inside a `pipe_through` that requires an administrator and a `live_session` with an `on_mount` that checks the same. A LiveView socket outlives the request, so also give your sockets a `live_socket_id` and disconnect it on logout.
- **Give it an `:actor`.** The option is required: a router that leaves it out does not compile, so the page never acts for nobody. The page calls it with the socket and uses the result as the actor that is recorded as the decider and replays a merge. A function that returns `nil` means nobody is signed in and the page refuses every action. A tool with no users returns a constant.
- **Optionally, give it an `:owner`.** `owner: {MyAppWeb.Inspector, :owner}` is called with the actor and returns the owner whose branches the page shows: it lists, refreshes, forks and acts on those only, and forks it creates belong to that owner. If the actor or the owner is `nil` it shows nothing. Without the option the page shows every branch of the domain. A user who can open the route still reaches the LiveView socket; the page ignores events for other owners' branches, and the same limit as above applies: this is a view, and the branch ids are not secret from the host's own code.
- **One `live_session` per level of access.** A LiveView joins with a URL the browser sends, and the page reads its options from the route that URL matches. Two `ramal_inspector` mounts in one `live_session` therefore share authorization: a user allowed into one can make the page use the options of the other. Put mounts that differ in who may use them in separate `live_session`s.
- **CSRF and origin.** The page has no form and no controller action; every change is a LiveView event on the socket, which Phoenix protects with the socket's CSRF token and `check_origin`. Keep `check_origin` on in production.
- **Destructive actions** (merge, discard, approve, reject) need a second event that the server accepts only after the first, per socket. Fork does not ask and creates a branch (a process and a stored row): set the limits below, and rate limit the route if untrusted users reach it.
- **Values.** Attributes marked `sensitive?: true` show as `[redacted]` in the diff. Other values are shown, cut to 80 characters, to everyone who can open the page.
- **Output.** Every value is rendered through HEEx, which escapes it. The one `raw/1` is the page's static stylesheet, which a content security policy without `style-src 'unsafe-inline'` blocks.

### Limiting how many branches exist

Every branch is a stored row and, while in use, a process, and `Ramal.branch/2` and `Ramal.fork/2` (which the inspector calls) create one per call. Ramal sets no limit by default, because a limit that is right for one application refuses legitimate work in another. Set one on `Ramal.Supervisor` when untrusted or automated callers can reach those functions:

```elixir
{Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo,
 max_active_branches: 200, branch_rate: {20, :timer.minutes(1)}}
```

- `:max_active_branches` caps the open and proposed branches of each domain.
- `:branch_rate` caps the branches and forks created per domain in a window, counted in memory on each node.

A refused call returns `{:error, %Ramal.Error{reason: :limit_reached}}` and emits `[:ramal, :limit, :reached]`. Both limits are per domain, not per user: they bound the damage, they do not share it fairly, so scope branch ids and who may fork to your users in your own code. `:max_active_branches` is soft (callers creating at the same instant can pass it by their own number) and `:branch_rate` uses fixed windows (a burst across the end of a window can reach twice the rate). With `Ramal.Storage.Postgres` the count is one query per creation, and with a custom storage that does not define `count/3` it is a `list/3`, which reads every stored branch of the domain.
