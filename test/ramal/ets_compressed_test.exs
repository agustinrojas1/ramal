defmodule Ramal.EtsCompressedTest do
  use Ramal.BranchCase, async: false

  alias Ramal.Supervisor, as: RamalSupervisor

  test "default tables are not compressed" do
    for table <- [Ramal.Storage.ETS.table(), Ramal.Storage.ETS.index_table(), Ramal.Storage.ETS.writes_table(), RamalSupervisor.table()] do
      assert :ets.info(table, :compressed) == false
    end
  end

  @tag supervisor: [ets_compressed: true]
  test "compressed tables when requested" do
    for table <- [Ramal.Storage.ETS.table(), Ramal.Storage.ETS.index_table(), Ramal.Storage.ETS.writes_table(), RamalSupervisor.table()] do
      assert :ets.info(table, :compressed) == true
    end
  end

  @tag supervisor: false
  test "invalid value raises" do
    assert {:error, {{%ArgumentError{message: message}, _}, _}} =
             start_supervised({RamalSupervisor, ets_compressed: :nope})

    assert message =~ "ets_compressed"
  end

  test "validator accepts booleans" do
    assert RamalSupervisor.ets_compressed(true) == true
    assert RamalSupervisor.ets_compressed(false) == false
  end

  test "validator rejects non-booleans" do
    assert_raise ArgumentError, ~r/ets_compressed/, fn ->
      RamalSupervisor.ets_compressed(:nope)
    end
  end
end
