defmodule Ramal.DataCase do
  @moduledoc false
  # Every test gets its own sandboxed connection, rolled back at the end.
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Ramal.TestRepo

  using do
    quote do
      alias Ramal.Test.Farm
      alias Ramal.Test.Farm.{Herd, Move, Paddock, Seeds}
      alias Ramal.TestRepo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
