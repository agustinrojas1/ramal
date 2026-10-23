defmodule RamalLive.Test.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :ramal_live

  @session_options [
    store: :cookie,
    key: "_ramal_live_test",
    signing_salt: "ramal-live-test",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(RamalLive.Test.Router)
end

defmodule RamalLive.Test.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <.live_title>{assigns[:page_title]}</.live_title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule RamalLive.Test.Inspector do
  @moduledoc false

  # `actor: {RamalLive.Test.Inspector, :actor}`: the host reads its current user from the socket's assigns.
  def actor(socket), do: socket.assigns[:current_user]

  # `owner: {RamalLive.Test.Inspector, :owner}`: the owner of a signed-in user's branches.
  def owner(actor), do: actor.name

  # An owner function that finds no owner for a user who is signed in.
  def no_owner(_actor), do: nil

  # A session that ended: the function the host wrote finds no user.
  def nobody(_socket), do: nil

  # An on_mount hook of the host's live_session, as `UserAuth` would be.
  def on_mount(:default, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_user, %{name: "Marta", role: :admin})}
  end
end
