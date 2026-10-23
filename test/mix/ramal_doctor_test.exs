defmodule Mix.Tasks.Ramal.DoctorTest do
  # `render/2` is the report and the exit status of `mix ramal.doctor`. The checks themselves run in
  # test/ramal/ash_contract_shipped_test.exs; these tests feed it fabricated results, so every status can be seen.
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ramal.Doctor
  alias Ramal.Ash.Contract

  @env %{ramal: "0.8.0", ash: "3.37.0", ash_postgres: "2.15.1"}

  defp all_ok, do: for(%{id: id} <- Contract.assumptions(), do: {id, :ok})

  defp with_result(results, id, outcome),
    do: List.keyreplace(results, id, 0, {id, outcome})

  test "an all-ok run lists every assumption, says ok and exits 0" do
    {report, status} = Doctor.render(all_ok(), @env)

    assert status == 0
    assert report =~ "Ramal 0.8.0 on Ash 3.37.0 (tested: ~> 3.36.0 or ~> 3.37.0)"
    assert report =~ "AshPostgres 2.15.1 (tested: ~> 2.15.0)"

    for %{id: id, summary: summary} <- Contract.assumptions() do
      assert report =~ to_string(id)
      assert report =~ summary
    end

    assert report =~ "Verdict: ok. #{length(Contract.assumptions())} checks passed."
    refute report =~ "BROKEN"
  end

  test "a broken core assumption prints its reason and exits 1" do
    results = with_result(all_ok(), :set_result_update, {:broken, "the update wrote the row"})

    {report, status} = Doctor.render(results, @env)

    assert status == 1
    assert report =~ "BROKEN"
    assert report =~ "reason: the update wrote the row"
    assert report =~ "Verdict: BROKEN"
    assert report =~ "set_result_update"
  end

  test "a broken extended assumption exits 0 and names the feature Ramal refuses" do
    results = with_result(all_ok(), :upsert_condition, {:broken, "no condition"})

    {report, status} = Doctor.render(results, @env)

    assert status == 0
    assert report =~ "BROKEN"
    assert report =~ "partly broken"
    assert report =~ "refuses upserts"
    assert report =~ "everything else works"
  end

  test "a core assumption broken with an extended one is an exit 1" do
    results =
      all_ok()
      |> with_result(:upsert_flag, {:broken, "x"})
      |> with_result(:accessing_from, {:broken, "y"})

    assert {_report, 1} = Doctor.render(results, @env)
  end

  test "a check that is not run is listed as not checked, and does not fail the run" do
    results = with_result(all_ok(), :bulk_context_markers, :not_checked)

    {report, status} = Doctor.render(results, @env)

    assert status == 0
    assert report =~ "not checked"
    assert report =~ "1 not checked"
  end

  test "an Ash that is not installed is named as such" do
    {report, _status} = Doctor.render(all_ok(), %{@env | ash_postgres: nil})

    assert report =~ "AshPostgres not installed"
  end
end
