defmodule Ramal.BranchCase do
  @moduledoc false
  # Starts Ramal.Supervisor for each test (there is one per node, so these tests are not async) and helpers to
  # observe it. Tune the supervisor with `@tag supervisor: [idle_timeout: 50]`, or disable it with `supervisor: false`.
  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  using do
    quote do
      import Ramal.BranchCase

      alias Ramal.{Branch, Error, Overlay}
      alias Ramal.Branch.Server
    end
  end

  setup tags do
    case Map.get(tags, :supervisor, []) do
      false -> :ok
      opts -> start_supervised!({Ramal.Supervisor, opts})
    end

    :ok
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

  @doc "Sends `{:telemetry, event, metadata}` to the test process for every Ramal branch event until the test ends."
  def capture_branch_events do
    test = self()
    handler = "branch-events-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      Ramal.Telemetry.branch_events(),
      fn event, _measurements, metadata, _config -> send(test, {:telemetry, event, metadata}) end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc "Whether a process for branch `id` is running."
  def loaded?(id), do: Ramal.Supervisor.whereis(id) != nil

  @doc """
  What a crash of the node leaves: the branch process gone without running `terminate/2`, and its marks cleared as a
  restart clears them (the ETS tables of the supervisor are the only thing a test cannot lose, and storage is one of
  them).
  """
  def crash(id) do
    pid = Ramal.Supervisor.whereis(id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    eventually(fn -> Ramal.Supervisor.too_large?(id) end)
    Ramal.Supervisor.clear_too_large(id)
    Ramal.Supervisor.clear_running(id)
    eventually(fn -> not loaded?(id) end)
  end
end
