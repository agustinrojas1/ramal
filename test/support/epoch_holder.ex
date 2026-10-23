defmodule Ramal.Test.EpochHolder do
  @moduledoc false
  # Stands in for a branch process when `Ramal.Cluster.resolve/3` asks it for its epoch and tells it to stop.
  use GenServer

  def start_link({epoch, test}), do: GenServer.start_link(__MODULE__, {epoch, test})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:epoch, _from, {epoch, _test} = state), do: {:reply, epoch, state}

  @impl true
  def handle_cast(:superseded, {_epoch, test} = state) do
    send(test, {:superseded, self()})
    {:noreply, state}
  end
end
