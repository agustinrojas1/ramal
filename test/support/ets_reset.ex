defmodule Ramal.Test.Ets do
  @moduledoc false
  # Ash.DataLayer.Ets.stop/1 shuts the table's manager process down with Process.exit/2, which returns before the
  # manager is gone. A test that creates a row straight afterwards can find the dying manager, wrap its table and
  # lose it mid-test ("Attempted to update stale record"). Waiting for the process to exit makes the reset complete.

  alias Ash.DataLayer.Ets
  alias Ash.DataLayer.Ets.Info

  @doc "The registered manager process of a resource's table (Ash.DataLayer.Ets.TableManager), or nil."
  @spec manager(module) :: pid | nil
  def manager(resource),
    do: Process.whereis(Module.concat(Info.table(resource), Ets.TableManager))

  @spec reset(module) :: :ok
  def reset(resource) do
    pid = manager(resource)
    ref = pid && Process.monitor(pid)

    Ets.stop(resource)

    if ref do
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        1_000 -> raise "the ETS table manager of #{inspect(resource)} did not stop"
      end
    end

    :ok
  end
end
