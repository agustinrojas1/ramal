defmodule RamalLive.Events do
  @moduledoc false
  # The bridge between Ramal's telemetry and the host's PubSub, kept free of processes so it can be tested with plain
  # data. `RamalLive.Broadcaster` attaches `handle/4`; `RamalLive.InspectorLive` subscribes to `topic/1`.
  #
  # Only the events that change what a column shows are attached. `[:ramal, :branch, :load | :unload]` do not: the
  # overlay is the same before and after, and a loaded branch is already on screen.

  @events [
    [:ramal, :branch, :create],
    [:ramal, :branch, :fork],
    [:ramal, :branch, :discard],
    [:ramal, :branch, :propose],
    [:ramal, :branch, :approve],
    [:ramal, :branch, :reject],
    [:ramal, :branch, :too_large],
    # A merge span ends with `stop` whether it succeeded or not; either way the branch's status may have changed.
    [:ramal, :merge, :stop],
    [:ramal, :write, :capture]
  ]

  @doc "The telemetry events the inspector listens to."
  @spec events() :: [[atom]]
  def events, do: @events

  @doc """
  The PubSub topic for the branches of `domain`.

  `Atom.to_string/1` on an existing atom never creates one.
  """
  @spec topic(module) :: String.t()
  def topic(domain) when is_atom(domain), do: "ramal_live:" <> Atom.to_string(domain)

  @doc "The message broadcast for a telemetry event: only the branch id and the event, never the event's data."
  @spec message([atom], String.t()) :: {:ramal_live, String.t(), [atom]}
  def message(event, branch_id), do: {:ramal_live, branch_id, event}

  @doc false
  # The telemetry handler. It runs in the process that emitted the event (a branch process, or the caller of
  # `Ramal.run/2`), so it must be quick and must never raise: telemetry detaches a handler that does.
  def handle(event, _measurements, %{branch_id: id, domain: domain}, %{pubsub: pubsub}) do
    Phoenix.PubSub.broadcast(pubsub, topic(domain), message(event, id))
    :ok
  rescue
    # The PubSub is not running (yet, or any more). Dropping the update is better than losing the handler.
    ArgumentError -> :ok
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok
end
