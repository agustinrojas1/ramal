# 0014. The inspector is a separate project mounted by a router macro in the host's own live_session

Status: accepted, 2026-10-22. Issue: #32.

## Context

The roadmap promises an inspector: open and proposed branches as columns, each branch's diff, buttons to fork, merge,
discard, approve and reject, and live updates. Core takes no Phoenix dependency (decision 6), so it lives in its own
package. Two questions shaped it: how a LiveView page gets into a host that already has a LiveView socket and
JavaScript, and how it learns that a branch changed.

`Phoenix.LiveDashboard` mounts with a router macro that opens a `live_session` of its own, with its own root layout and
its own compiled JavaScript. That makes it work anywhere, and costs an asset pipeline and a second socket setup.

## Decision

- **`ramal_live/` is a separate Mix project** in this repository. It depends on `ramal` by path and nothing depends on
  it. It has its own CI job and its own `mix.lock`.
- **`ramal_inspector "/ramal", domain: ..., pubsub: ...` expands to one `live` route and nothing else.** It opens no
  `live_session`, sets no root layout and ships no JavaScript or CSS file. The host places it inside its own scope,
  pipeline and `live_session`, so the page uses the host's root layout, socket and JS, and its authentication hooks
  apply. The CSS is inline in the page, scoped to a `.ramal` root.
- **The options travel as route metadata.** A `live` route cannot take a per-route session, and the session belongs to
  the host's `live_session`. The page reads its options back with `Phoenix.Router.route_info/4` for the URL it was
  reached at. A route mounted with plain `live` fails with a message that names `ramal_inspector`.
- **Live updates are telemetry to PubSub to a read of one branch.** `RamalLive.Broadcaster`, a process the host starts,
  attaches handlers for the branch events, `[:ramal, :write, :capture]` and `[:ramal, :merge, :stop]`, and broadcasts
  `{:ramal_live, branch_id, event}` on a topic per domain. The message carries no row data. The page re-reads only the
  branch it names (`Ramal.get/1` and `Ramal.diff/1`, so the page sees what the public API shows), and coalesces a burst
  of writes into one read per `:debounce` window.
- **The broadcaster is supervised, not attached by the first page view.** Telemetry is node-local and a branch emits
  its events whether or not anyone is looking, so a handler attached on first mount would miss every event before it.
  A page without a broadcaster says so and works on actions and Reload.
- **Authorization is the host's.** The inspector can merge and discard. It checks nothing itself; an `:actor`
  option, `{module, function}` called with the socket, supplies the actor recorded as `decided_by` and used to replay.
- **Merge and approve run in `start_async`**, since they replay a log in a transaction; the other actions are quick and
  run in the LiveView. Every destructive action has a server-side confirmation: the second event is accepted only after
  the first.

## Consequences

- `ramal_live` needs LiveView 1.1 or later.
- Opening the page loads the process of every branch it shows (`Ramal.get/1` does). They unload on `idle_timeout`.
  There is no pagination: a column shows its first 100 changes and counts the rest.
- Several `ramal_inspector` mounts can share one PubSub and one broadcaster; two broadcasters for one PubSub are refused.
- A host with a strict content security policy must allow the inline `<style>`.
- Dropped from the first reading of the issue: a route per branch, a propose button, free-text reasons on approve and
  reject. Each would be its own decision.
