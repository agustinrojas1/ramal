# RamalLive

A LiveView inspector for [Ramal](../README.md) branches. Not on Hex yet.

It shows the open and proposed branches of one Ash domain as columns. Each column has the branch's name, status, age and
overlay size, and its `Ramal.diff/1` as before and after rows. Buttons fork, merge and discard an open branch and approve
or reject a proposal; merge, discard, approve and reject ask for a second click first. While the page is open, Ramal's
telemetry updates the columns, and only the branch that changed is read again.

There is no JavaScript, no Tailwind and no asset pipeline. The page is a LiveView with inline CSS (slate for the base line,
copper for branches, light and dark themes), mounted by your router inside your own `live_session`, so it uses your
LiveView socket and your JavaScript. The decision is in [ADR 0015](../docs/adr/0015-inspector-mounting.md).

## Setup

Requires Phoenix 1.7+, Phoenix LiveView 1.1+ and a running `Phoenix.PubSub`.

```elixir
# mix.exs: not on Hex yet, so use a checkout of this repository, which holds both packages
{:ramal, path: "../ramal"},
{:ramal_live, path: "../ramal/ramal_live"}

# application.ex, after the PubSub and Ramal.Supervisor, in every node that runs branches
{RamalLive.Broadcaster, pubsub: MyApp.PubSub}

# router.ex, behind your own authorization
import RamalLive.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]

  live_session :admin, on_mount: [{MyAppWeb.UserAuth, :ensure_admin}] do
    ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub
  end
end
```

Options of `ramal_inspector/2`: `:domain` and `:pubsub` (required), `:actor` (`{module, function}`, called with the socket,
returns the actor that is recorded as `decided_by` and replays a merge) and `:debounce` (milliseconds, default 50).

## Things to know

- **Authorization is yours.** Whoever opens the page can merge and discard any branch of the domain. Ramal records who
  decided and never checks.
- **Fonts.** Headings ask for Barlow Condensed and data for IBM Plex Mono. The page loads neither; add the link tag to your
  root layout if you want them, or the system's condensed and monospace fonts are used.
- **Content security policy.** The CSS is an inline `<style>`; a policy without `style-src 'unsafe-inline'` blocks it.
- **Reading loads branches.** The page reads each branch it shows with `Ramal.get/1`, which starts its process if it was
  unloaded; it unloads again after `idle_timeout`. A column shows the first 100 changes and counts the rest.
- **Without the broadcaster** the page works but only changes after an action made on it or on Reload, and says so.
- **Telemetry.** Every read of a branch emits `[:ramal_live, :column, :read]` with `%{branch_id, domain}` metadata and a
  `duration` measurement.

## Development

```bash
cd ramal_live
mix deps.get
mix ci          # format, compile with warnings as errors, credo strict, tests
```

The tests run on a test endpoint with `Phoenix.LiveViewTest` and an ETS-backed domain, so no database is needed.
