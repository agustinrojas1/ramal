defmodule Ramal.AshBootTest do
  # The boot check of Ramal.Supervisor, run by init/1 on the loaded Ash and AshPostgres (ADR 0049). `ash_boot_check/1`
  # takes the versions as arguments, so these tests run it on versions the host does not have and leave the real Ash
  # alone. Inside the tested range it only clears the broken ids. Outside it, it warns, runs Ramal's Ash contract and
  # emits [:ramal, :ash, :contract] with the versions it was given. The contract passes on the locked Ash, so nothing is
  # broken here; a broken assumption is covered by ash_incompatible_test.exs, which sets the ids directly.
  #
  # The broken ids and the telemetry handler are node-wide, so this module is not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ramal.Ash.Contract
  alias Ramal.Supervisor

  @event [:ramal, :ash, :contract]

  setup do
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      @event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:ash_contract, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Contract.put_broken([])
    end)

    :ok
  end

  test "inside the tested range the boot check clears the broken ids and runs no contract" do
    Contract.put_broken([:set_result_create])

    log =
      capture_log(fn ->
        assert :ok = Supervisor.ash_boot_check(%{ash: "3.37.0", ash_postgres: "2.15.1"})
      end)

    assert Contract.broken() == []
    assert log == ""
    refute_received {:ash_contract, _, _}
  end

  test "an AshPostgres that is not installed is not checked" do
    log =
      capture_log(fn ->
        assert :ok = Supervisor.ash_boot_check(%{ash: "3.37.0", ash_postgres: nil})
      end)

    assert log == ""
    refute_received {:ash_contract, _, _}
  end

  test "outside the tested range the boot check warns, runs the contract and emits the event with those versions" do
    log =
      capture_log(fn ->
        assert :ok = Supervisor.ash_boot_check(%{ash: "3.38.0", ash_postgres: "2.15.1"})
      end)

    assert log =~
             "Ramal is running with ash 3.38.0, outside the range it is tested with (~> 3.36.0 or ~> 3.37.0)"

    assert log =~
             "Ramal's Ash contract passed on ash 3.38.0, all #{length(Contract.assumptions())} checks"

    assert Contract.broken() == []

    assert_received {:ash_contract, %{broken: 0},
                     %{broken: [], ash: "3.38.0", ash_postgres: "2.15.1"}}
  end

  test "an AshPostgres outside its range alone is enough to run the contract, and the warning names it" do
    log =
      capture_log(fn ->
        assert :ok = Supervisor.ash_boot_check(%{ash: "3.37.0", ash_postgres: "2.16.0"})
      end)

    assert log =~
             "Ramal is running with ash_postgres 2.16.0, outside the range it is tested with (~> 2.15.0)"

    assert Contract.broken() == []

    assert_received {:ash_contract, %{broken: 0}, %{ash: "3.37.0", ash_postgres: "2.16.0"}}
  end
end
