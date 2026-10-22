defmodule RamalLive.Broadcaster do
  @moduledoc """
  Turns Ramal's telemetry into PubSub messages, so that open inspectors update as branches change.

  Add it to the host's supervision tree after the PubSub and `Ramal.Supervisor`:

      children = [
        {Phoenix.PubSub, name: MyApp.PubSub},
        {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo},
        {RamalLive.Broadcaster, pubsub: MyApp.PubSub}
      ]

  It attaches telemetry handlers for the branch lifecycle events, `[:ramal, :write, :capture]` and the end of
  `[:ramal, :merge]`, and detaches them when it stops. A handler broadcasts `{:ramal_live, branch_id, event}` on the
  topic of the branch's domain and nothing else, so no row data travels through the PubSub. Telemetry is node-local,
  and so are branches (a branch lives on one node), which is why the broadcaster belongs in the tree of every node that
  runs `Ramal.Supervisor`.

  The inspector works without it, but only shows what was there when the page loaded or after an action made from the
  page, and says so.

  ## Options

    * `:pubsub` - the host's `Phoenix.PubSub` name. Required, and the same one given to `ramal_inspector/2`.

  ## Example

      {:ok, _pid} = RamalLive.Broadcaster.start_link(pubsub: MyApp.PubSub)
      RamalLive.Broadcaster.attached?(MyApp.PubSub)
      #=> true
  """

  use GenServer

  alias RamalLive.Events

  @doc """
  Starts the broadcaster. See the module doc for the options.

  Stops with `{:already_attached, pubsub}` when another broadcaster for the same PubSub is running, since every event
  would be broadcast twice.
  """
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    GenServer.start_link(__MODULE__, pubsub)
  end

  @doc """
  Whether a broadcaster for `pubsub` is attached on this node.

  ## Example

      RamalLive.Broadcaster.attached?(MyApp.PubSub)
      #=> false
  """
  @spec attached?(atom) :: boolean
  def attached?(pubsub) when is_atom(pubsub) do
    handler = handler_id(pubsub)

    :telemetry.list_handlers([:ramal, :write, :capture])
    |> Enum.any?(&(&1.id == handler))
  end

  @impl true
  def init(pubsub) do
    # Trapping exits makes the supervisor's shutdown call terminate/1, which detaches the handlers.
    Process.flag(:trap_exit, true)

    attached =
      :telemetry.attach_many(handler_id(pubsub), Events.events(), &Events.handle/4, %{
        pubsub: pubsub
      })

    case attached do
      :ok -> {:ok, pubsub}
      {:error, :already_exists} -> {:stop, {:already_attached, pubsub}}
    end
  end

  @impl true
  def terminate(_reason, pubsub) do
    :telemetry.detach(handler_id(pubsub))
    :ok
  end

  defp handler_id(pubsub), do: {__MODULE__, pubsub}
end
