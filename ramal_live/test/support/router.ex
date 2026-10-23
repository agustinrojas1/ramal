defmodule RamalLive.Test.Router do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import RamalLive.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:put_root_layout, html: {RamalLive.Test.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)

    live_session :admin, on_mount: [{RamalLive.Test.Inspector, :default}] do
      ramal_inspector("/ramal",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :actor}
      )

      ramal_inspector("/ramal-debounced",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 40,
        actor: {RamalLive.Test.Inspector, :actor}
      )

      # Mounted with `live`, which carries no options: the page has to say what went wrong.
      live("/bare", RamalLive.InspectorLive, :index)

      ramal_inspector("/ramal-actor",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :actor}
      )

      # Mounted with an `:actor` whose function does not exist: the page says so when it opens.
      ramal_inspector("/ramal-typo",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :no_such_function}
      )

      # Each user sees their own branches only.
      ramal_inspector("/ramal-owned",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :actor},
        owner: {RamalLive.Test.Inspector, :owner}
      )

      # Mounted with an `:owner` whose function does not exist: the page says so when it opens.
      ramal_inspector("/ramal-typo-owner",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :actor},
        owner: {RamalLive.Test.Inspector, :no_such_owner}
      )

      # The owner function finds no owner for the signed-in user.
      ramal_inspector("/ramal-no-owner",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :actor},
        owner: {RamalLive.Test.Inspector, :no_owner}
      )

      # The host's actor function finds nobody signed in.
      ramal_inspector("/ramal-nobody",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :nobody}
      )
    end
  end
end
