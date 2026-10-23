defmodule Ramal.Cluster do
  @moduledoc false
  # The registry of branch processes when `Ramal.Supervisor` runs with `cluster: true` (ADR 0039): a `:via` module over
  # `:global`, so that every node finds the one process of a branch, wherever it runs.
  #
  # `:global` registers a name on all connected nodes under a lock, and after a netsplit heals it finds a name two nodes
  # registered on their own side. It then asks a resolve function which of the two processes keeps the name and expects
  # the function to stop the other (the default one kills it, which would skip `terminate/2`). `resolve/3` keeps the
  # process with the higher epoch, because the storage already refuses the writes of the other one (Ramal.Storage's
  # `claim/2`), and asks the loser to stop through its own persist path.
  #
  # `:global.register_name/3` takes the resolve function, which gets the name and the two pids and returns the one to
  # keep; the tests with real nodes (test/ramal/cluster_nodes_test.exs) show that the process it returns keeps the name
  # on both nodes once they meet and that the one it drops receives the message.

  @ask_timeout 1_000

  @doc false
  def name(id), do: {Ramal.Branch, id}

  @doc false
  def register_name(id, pid), do: :global.register_name(name(id), pid, &resolve/3)

  @doc false
  def unregister_name(id), do: :global.unregister_name(name(id))

  @doc false
  def whereis_name(id), do: :global.whereis_name(name(id))

  @doc false
  def send(id, message), do: :global.send(name(id), message)

  @doc false
  # Keeps the process whose epoch is higher (the first one when they are equal or one does not answer), and tells the
  # other to stop. The loser's own persist is refused by the storage when its epoch is lower, so asking it to stop
  # cannot overwrite the winner's state; when it is not (the winner's epoch could not be read), it saves what it has.
  def resolve(_name, pid1, pid2) do
    {keep, drop} = if epoch(pid2) > epoch(pid1), do: {pid2, pid1}, else: {pid1, pid2}
    GenServer.cast(drop, :superseded)
    keep
  end

  defp epoch(pid) do
    GenServer.call(pid, :epoch, @ask_timeout) || -1
  catch
    :exit, _reason -> -1
  end
end
