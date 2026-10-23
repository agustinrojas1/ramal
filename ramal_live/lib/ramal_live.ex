defmodule RamalLive do
  @moduledoc """
  A LiveView inspector for [Ramal](https://github.com/agustinrojas1/ramal) branches.

  It shows the open and proposed branches of one Ash domain as columns. Each column has the branch's name, status, age
  and overlay size, and its `Ramal.diff/1` as before and after rows. Buttons fork, merge and discard an open branch and
  approve or reject a proposal; merge, discard, approve and reject ask for a second click first. While the page is open,
  Ramal's telemetry keeps the columns current: only the branch that changed is read again.

  `ramal_live` is a separate package that depends on `ramal`. Ramal itself never depends on it, and it has no JavaScript,
  no Tailwind and no asset pipeline: the page is a LiveView with inline CSS, mounted by the host's router inside the host's
  own `live_session`, so it uses the host's socket and the host's JavaScript.

  ## Setup

  1. Depend on it, from [Hex](https://hex.pm/packages/ramal_live):

         {:ramal, "~> 0.6.0"},
         {:ramal_live, "~> 0.6.0"}

  2. Start `RamalLive.Broadcaster` after the PubSub and `Ramal.Supervisor`, in every node that runs branches:

         {RamalLive.Broadcaster, pubsub: MyApp.PubSub}

  3. Mount the page in the router, behind the host's authorization (see `RamalLive.Router`):

         import RamalLive.Router

         scope "/admin" do
           pipe_through [:browser, :require_admin]

           live_session :admin, on_mount: [{MyAppWeb.UserAuth, :ensure_admin}] do
             ramal_inspector "/ramal", domain: MyApp.Farm, pubsub: MyApp.PubSub, actor: {MyAppWeb.Inspector, :actor}
           end
         end

  ## Things to know

    * **Authorization is the host's.** Whoever can open the page can merge and discard any branch of the domain. Ramal
      records who decided but never checks; `RamalLive.Router` requires an `:actor` option to pass the current user along.
    * **Fonts.** Headings ask for Barlow Condensed and data for IBM Plex Mono. The page does not load them, so a host that
      wants them adds the link tag to its root layout; otherwise the system's condensed and monospace fonts are used.
    * **Content security policy.** The CSS is an inline `<style>` element. A policy without `style-src 'unsafe-inline'`
      blocks it.
    * **Reading loads.** The page reads each branch it shows with `Ramal.get/1`, which starts the branch's process if it
      was unloaded. Processes unload again after `Ramal.Supervisor`'s `idle_timeout`.
    * **Telemetry.** Every read of a branch emits `[:ramal_live, :column, :read]`, with `%{branch_id, domain}` metadata and
      a `duration` measurement in native time units.
    * **Themes.** The page follows `prefers-color-scheme`; the buttons in its header pick a theme for the open page only.
  """
end
