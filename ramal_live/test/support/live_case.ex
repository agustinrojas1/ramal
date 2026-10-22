defmodule RamalLive.LiveCase do
  @moduledoc false
  # Starts what the host's application would: the PubSub, `Ramal.Supervisor` and the test endpoint. Ramal has one
  # supervisor per node, so these tests are not async.
  use ExUnit.CaseTemplate

  alias Ash.DataLayer.Ets
  alias Phoenix.ConnTest
  alias RamalLive.Test.Farm.Herd

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import RamalLive.LiveCase

      alias RamalLive.Test.Farm
      alias RamalLive.Test.Farm.Herd

      @endpoint RamalLive.Test.Endpoint
    end
  end

  setup do
    start_supervised!({Phoenix.PubSub, name: RamalLive.Test.PubSub})
    start_supervised!({Ramal.Supervisor, []})
    start_supervised!(RamalLive.Test.Endpoint)

    # ETS tables are named by resource and outlive a test; start each one empty.
    Ets.stop(Herd)
    on_exit(fn -> Ets.stop(Herd) end)

    {:ok, conn: ConnTest.build_conn()}
  end

  @doc "Creates a herd in the base (outside any branch)."
  def herd!(name, head), do: Ash.create!(Herd, %{name: name, head: head})

  @doc "Opens a branch of the test farm that already holds `fun`'s writes."
  def branch!(name, fun \\ fn -> :ok end) do
    {:ok, branch} = Ramal.branch(RamalLive.Test.Farm, name: name)
    Ramal.run!(branch, fun)
    {:ok, branch} = Ramal.get(branch.id)
    branch
  end

  @doc "Polls `fun` until it returns a truthy value, failing after `timeout` ms."
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "condition not met in time"
        else
          Process.sleep(10)
          poll(fun, deadline)
        end

      value ->
        value
    end
  end
end
