# RamalLive

**A live inspector for [Ramal](https://github.com/agustinrojas1/ramal) branches: see every alternative state of your data side by side, and merge, discard or approve them with a click.**

[![Hex.pm](https://img.shields.io/hexpm/v/ramal_live.svg)](https://hex.pm/packages/ramal_live) [![HexDocs](https://img.shields.io/badge/hexdocs-ramal__live-blue.svg)](https://hexdocs.pm/ramal_live)

![The inspector with four open branches, each moving herd R7 to a different paddock, shown as columns of before and after rows](https://raw.githubusercontent.com/agustinrojas1/ramal/main/assets/inspector.png)

[Ramal](https://hex.pm/packages/ramal) gives an Ash application Git-style branches of its data: a branch is a process
that holds a few changes on top of your database, and nothing reaches the database until the branch is merged. That is
easy to use from code and hard to *see*. RamalLive is the page that shows it: one column per branch, with what that
branch would change.

## What you see

It shows the open and proposed branches of one Ash domain as columns:

- **The header:** the branch's name, status, age and overlay size, who proposed it and why, and which branch it was forked from.
- **The diff:** the branch's `Ramal.diff/1` as before and after rows, one per attribute that changed. A created row has
  no before values and a deleted row no after values. Attributes marked `sensitive?: true` show as `[redacted]`.
- **The buttons:** fork, merge and discard on an open branch; approve and reject on a proposal. Merge, discard, approve and
  reject ask for a second click first.
- **Live updates:** while the page is open, Ramal's telemetry updates the columns as an agent or a request writes to a
  branch, and only the branch that changed is read again.

## Who it is for

- **You, while building** an agent or a what-if feature on Ramal: watch the branches your code opens, see what each one
  changed and why a merge was refused as stale.
- **A reviewer** who approves or rejects what an agent proposed with `Ramal.propose/2`, reading the diff before deciding.
- **An operator** who needs to find and discard branches that were left open.

There is no JavaScript, no Tailwind and no asset pipeline. The page is a LiveView with inline CSS (slate for the base line,
copper for branches, light and dark themes), mounted by your router inside your own `live_session`, so it uses your
LiveView socket and your JavaScript. The decision is in [ADR 0015](https://github.com/agustinrojas1/ramal/blob/main/docs/adr/0015-inspector-mounting.md).

## Setup

Requires Phoenix 1.7+, Phoenix LiveView 1.1+ and a running `Phoenix.PubSub`.

```elixir
# mix.exs
{:ramal, "~> 0.2.0"},
{:ramal_live, "~> 0.2.0"}

# application.ex, after the PubSub and Ramal.Supervisor, in every node that runs branches
{RamalLive.Broadcaster, pubsub: MyApp.PubSub}

# router.ex, behind your own authorization
import RamalLive.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]

  live_session :admin, on_mount: [{MyAppWeb.UserAuth, :ensure_admin}] do
    ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
  end
end
```

Options of `ramal_inspector/2`: `:domain`, `:pubsub` and `:actor` (all required), and `:owner` and `:debounce` (optional).
`:actor` is `{module, function}`; the page calls `module.function(socket)` and uses the result as the actor that is
recorded as `decided_by` and replays a merge, or refuses to act when it returns `nil`. A router without it does not compile.
For a development tool with no users, return a constant (`def actor(_socket), do: :dev`).

`:owner` is also `{module, function}` and off by default. When given, the page calls `module.function(actor)` with what
`:actor` returned and shows only the branches created with that owner (`Ramal.branch(domain, owner: ...)`), so each signed-in user
sees their own and forks they make belong to them. When the actor or the owner is `nil` it shows nothing. It is a view, not
access control (see below). `:debounce` is how many milliseconds the page waits to coalesce a burst of writes before it
reads the branch again (default 50).

```elixir
defmodule MyAppWeb.Inspector do
  def actor(socket), do: socket.assigns.current_user
  def owner(user), do: user && user.id
end

ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub,
  actor: {MyAppWeb.Inspector, :actor}, owner: {MyAppWeb.Inspector, :owner}
```

## When to use it

- **In development**, mounted with a constant actor, to watch what an agent or a feature does to its branches.
- **As an internal admin page**, behind your administrators' login, to review proposals and clean up stale branches.
- **Not as a user-facing page** unless you mount it with `:owner` *and* check the rest yourself: the page can merge, approve and
  discard, and it does not check who may. If your users should see only their own change, build that page on `Ramal.list/2`,
  `Ramal.diff/1` and `Ramal.merge/2` instead and use this one as a reference.

## Things to know

- **Authorization is yours.** Whoever opens the page can merge and discard any branch of the domain. Ramal records who
  decided and never checks. Mount it behind your own authentication in a `live_session` with an `on_mount` that checks the
  same, and give `:actor` (required) so decisions have a decider: when that function returns `nil` the page refuses every action.
  Mounts that differ in who may use them need separate `live_session`s, because the page reads its options from the URL the
  browser joins with. [SECURITY.md](https://github.com/agustinrojas1/ramal/blob/main/SECURITY.md) has the whole list.
- **`:owner` filters, it does not authorize.** The page ignores events for other owners' branches, but anyone who reaches the
  socket and holds a branch id is still bound only by your own checks.
- **Fork creates a branch**, which is a process and a stored row, and does not ask for confirmation. Set `:max_active_branches` and
  `:branch_rate` on `Ramal.Supervisor`, and rate limit the route if untrusted users can reach it.
- **Origin and sessions.** Every change is a LiveView event on your socket, protected by its CSRF token and `check_origin`: keep
  `check_origin` on in production, and give your sockets a `live_socket_id` and disconnect it on logout.
- **Secrets.** Attributes marked `sensitive?: true` show as `[redacted]` in the diff.
- **Fonts.** Headings ask for Barlow Condensed and data for IBM Plex Mono. The page loads neither; add the link tag to your
  root layout if you want them, or the system's condensed and monospace fonts are used.
- **Content security policy.** The CSS is an inline `<style>`; a policy without `style-src 'unsafe-inline'` blocks it.
- **Reading loads branches.** The page reads each branch it shows with `Ramal.get/1`, which starts its process if it was
  unloaded; it unloads again after `idle_timeout`. A column shows the first 100 changes and counts the rest.
- **Without the broadcaster** the page works but only changes after an action made on it or on Reload, and says so.
- **Telemetry.** Every read of a branch emits `[:ramal_live, :column, :read]` with `%{branch_id, domain}` metadata and a
  `duration` measurement.

## Try it

You do not need an app of your own to see the inspector. A runnable demo, the one the screenshot above and the animation below come from, lives in [`examples/farm_demo.exs`](https://github.com/agustinrojas1/ramal/blob/main/ramal_live/examples/farm_demo.exs). It needs Elixir 1.18+, Docker (for Postgres) and a clone of the repository. It is a single file that installs its own
dependencies with `Mix.install` (so the first start compiles for a few minutes), runs a [Phoenix
Playground](https://github.com/phoenixframework/phoenix_playground) app on a seeded farm in Postgres, and mounts the
inspector with the `ramal_inspector` line above.

```bash
docker compose up -d db                 # from the repository root: Postgres on port 5435
elixir ramal_live/examples/farm_demo.exs
```

Open <http://localhost:4000> and press **Explore 4 alternatives**. Here is what happens. Four branches open one after the other, each moves herd R7
out of paddock L07 into a different paddock, and the columns fill in as the writes happen. Merge one: the database now has
R7 in its new paddock, and merging any other column is refused as stale, because that branch read R7 where it used to be.
**Reset** discards every branch and seeds the farm again.

![The columns filling in as the four branches write](https://raw.githubusercontent.com/agustinrojas1/ramal/main/assets/inspector.gif)

The demo uses a `ramal_dev` database on the server of the test database, creates it if it is missing, and drops and
recreates its three tables on every start, so do not point it at data you want to keep. `RAMAL_PG_HOST`, `RAMAL_PG_PORT`,
`RAMAL_PG_USER` and `RAMAL_PG_PASSWORD` change the server and `PORT` changes the HTTP port. Branches are kept in ETS, so
they do not survive a restart. The page is the demo's own LiveView with the inspector in an iframe, so one URL shows both
the button and the columns.

## Development

```bash
cd ramal_live
mix deps.get
mix ci          # format, compile with warnings as errors, credo strict, tests
```

The tests run on a test endpoint with `Phoenix.LiveViewTest` and an ETS-backed domain, so no database is needed.
