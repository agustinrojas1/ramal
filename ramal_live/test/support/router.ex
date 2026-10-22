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
        debounce: 0
      )

      ramal_inspector("/ramal-debounced",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 40
      )

      # Mounted with `live`, which carries no options: the page has to say what went wrong.
      live("/bare", RamalLive.InspectorLive, :index)

      ramal_inspector("/ramal-actor",
        domain: RamalLive.Test.Farm,
        pubsub: RamalLive.Test.PubSub,
        debounce: 0,
        actor: {RamalLive.Test.Inspector, :actor}
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
