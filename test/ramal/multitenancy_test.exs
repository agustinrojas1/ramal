defmodule Ramal.MultitenancyTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use ExUnit.Case, async: false

  alias Ramal.Error
  alias Ramal.Test.Tenanted
  alias Ramal.Test.Tenanted.{Shared, Task}

  doctest Ramal.Resource

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, branch} = Ramal.branch(Tenanted)
    {:ok, branch: branch}
  end

  defp reason_of(error), do: error |> Error.find() |> Map.fetch!(:reason)

  test "a tenanted read inside a branch is refused with a message that says why", %{
    branch: branch
  } do
    assert {:error, error} =
             Ramal.run(branch, fn -> Ash.read(Task, tenant: "acme") end) |> unwrap()

    assert reason_of(error) == :multitenancy_unsupported
    assert Exception.message(Error.find(error)) =~ "does not partition"
  end

  test "a tenanted create inside a branch is refused and writes nothing", %{branch: branch} do
    assert {:error, error} =
             Ramal.run(branch, fn ->
               Ash.create(Task, %{org_id: "acme", title: "t"}, tenant: "acme")
             end)
             |> unwrap()

    assert reason_of(error) == :multitenancy_unsupported
    assert {:ok, %{overlay: overlay, log: []}} = Ramal.get(branch.id)
    assert overlay == %{}
  end

  test "a global multitenant resource still works without a tenant", %{branch: branch} do
    Ramal.run!(branch, fn ->
      Ash.create!(Shared, %{title: "shared"})
      assert [%{title: "shared"}] = Ash.read!(Shared)
    end)
  end

  test "outside a branch a tenanted resource is untouched" do
    task = Ash.create!(Task, %{org_id: "acme", title: "t"}, tenant: "acme")
    assert [%{id: id}] = Ash.read!(Task, tenant: "acme")
    assert id == task.id
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, _} = error), do: error
end
