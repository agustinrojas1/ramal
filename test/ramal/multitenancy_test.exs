defmodule Ramal.MultitenancyTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use ExUnit.Case, async: false

  alias Ramal.Error
  alias Ramal.Storage.Codec
  alias Ramal.Test.Ets
  alias Ramal.Test.Tenanted
  alias Ramal.Test.Tenanted.{Shared, Task}

  doctest Ramal.Resource

  setup do
    # An ETS table outlives the test that wrote to it.
    Enum.each([Task, Shared], &Ets.reset/1)
    start_supervised!(Ramal.Supervisor)
    {:ok, branch} = Ramal.branch(Tenanted)
    {:ok, branch: branch}
  end

  defp reason_of(error), do: error |> Error.find() |> Map.fetch!(:reason)

  test "a tenanted read inside a branch without a tenant is refused with a message that says why",
       %{
         branch: branch
       } do
    assert {:error, error} =
             Ramal.run(branch, fn -> Ash.read(Task, tenant: "acme") end) |> unwrap()

    assert reason_of(error) == :multitenancy_unsupported
    assert Exception.message(Error.find(error)) =~ "tenant: tenant"
  end

  test "a tenanted create inside a branch without a tenant is refused and writes nothing", %{
    branch: branch
  } do
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

  describe "a branch with a tenant" do
    setup do
      acme = Ash.create!(Task, %{org_id: "acme", title: "a1"}, tenant: "acme")
      globex = Ash.create!(Task, %{org_id: "globex", title: "g1"}, tenant: "globex")
      {:ok, branch} = Ramal.branch(Tenanted, tenant: "acme")
      {:ok, branch: branch, acme: acme, globex: globex}
    end

    defp titles(tasks), do: tasks |> Enum.map(& &1.title) |> Enum.sort()

    test "reads its tenant's base rows and the rows it created, not another tenant's", %{
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Task, %{org_id: "acme", title: "a2"}, tenant: "acme")
        assert titles(Ash.read!(Task, tenant: "acme")) == ["a1", "a2"]
      end)

      assert titles(Ash.read!(Task, tenant: "acme")) == ["a1"]
      assert titles(Ash.read!(Task, tenant: "globex")) == ["g1"]
    end

    test "updates and destroys rows of its tenant", %{branch: branch, acme: acme} do
      Ramal.run!(branch, fn ->
        Ash.update!(acme, %{title: "a1b"}, tenant: "acme")
        assert titles(Ash.read!(Task, tenant: "acme")) == ["a1b"]
        Ash.destroy!(acme, tenant: "acme")
        assert Ash.read!(Task, tenant: "acme") == []
      end)

      assert titles(Ash.read!(Task, tenant: "acme")) == ["a1"]
    end

    test "refuses another tenant on a read and a write, and writes nothing", %{branch: branch} do
      assert {:error, error} =
               Ramal.run(branch, fn -> Ash.read(Task, tenant: "globex") end) |> unwrap()

      assert reason_of(error) == :tenant_mismatch

      assert {:error, error} =
               Ramal.run(branch, fn ->
                 Ash.create(Task, %{org_id: "globex", title: "x"}, tenant: "globex")
               end)
               |> unwrap()

      assert reason_of(error) == :tenant_mismatch
      assert {:ok, %{overlay: overlay, log: []}} = Ramal.get(branch.id)
      assert overlay == %{}
    end

    test "merge replays the writes in its tenant and leaves the other tenants alone", %{
      branch: branch,
      acme: acme
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Task, %{org_id: "acme", title: "a2"}, tenant: "acme")
        Ash.update!(acme, %{title: "a1b"}, tenant: "acme")
      end)

      assert {:ok, [_, _]} = Ramal.diff(branch)
      assert {:ok, _result} = Ramal.merge(branch)
      assert titles(Ash.read!(Task, tenant: "acme")) == ["a1b", "a2"]
      assert titles(Ash.read!(Task, tenant: "globex")) == ["g1"]
    end

    test "merge finds a row of its tenant that changed under the branch", %{
      branch: branch,
      acme: acme
    } do
      Ramal.run!(branch, fn -> Ash.update!(acme, %{title: "from branch"}, tenant: "acme") end)
      Ash.update!(acme, %{title: "from base"}, tenant: "acme")

      assert {:error, error} = Ramal.merge(branch)
      assert reason_of(error) == :stale
    end

    test "a fork keeps the tenant and the tenant survives the stored form", %{branch: branch} do
      {:ok, fork} = Ramal.fork(branch)
      assert fork.tenant == "acme"
      assert {:ok, %{tenant: "acme"}} = Ramal.get(fork.id)

      {:ok, state} = Codec.encode_state(branch)
      columns = %{id: branch.id, domain: Atom.to_string(branch.domain), name: nil, status: "open"}
      assert {:ok, %{tenant: "acme"}} = Codec.decode_state(columns, state)
    end

    test "a global multitenant resource works without a tenant", %{branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.create!(Shared, %{title: "shared"})
        assert [%{title: "shared"}] = Ash.read!(Shared)
      end)
    end
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, _} = error), do: error
end
