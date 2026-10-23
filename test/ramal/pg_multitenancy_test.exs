defmodule Ramal.PgMultitenancyTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Error
  alias Ramal.Test.PgTenants
  alias Ramal.Test.PgTenants.{Note, Plot}

  setup do
    start_supervised!(Ramal.Supervisor)
    :ok
  end

  defp reason_of(error), do: error |> Error.find() |> Map.fetch!(:reason)
  defp titles(rows), do: rows |> Enum.map(& &1.title) |> Enum.sort()
  defp names(rows), do: rows |> Enum.map(& &1.name) |> Enum.sort()

  describe "the attribute strategy (one table, an org_id column)" do
    setup do
      acme = Ash.create!(Note, %{org_id: "acme", title: "a1"}, tenant: "acme")
      Ash.create!(Note, %{org_id: "globex", title: "g1"}, tenant: "globex")
      {:ok, branch} = Ramal.branch(PgTenants, tenant: "acme")
      {:ok, branch: branch, acme: acme}
    end

    test "a record of another tenant passed to an update or destroy is refused, as Ash refuses it",
         %{
           branch: branch
         } do
      globex = Ash.create!(Note, %{org_id: "globex", title: "g2"}, tenant: "globex")

      assert {:error, _error} = Ash.update(globex, %{title: "x"}, tenant: "acme")

      Ramal.run!(branch, fn ->
        assert {:error, error} = Ash.update(globex, %{title: "x"}, tenant: "acme")
        assert reason_of(error) == :tenant_mismatch
        assert {:error, error} = Ash.destroy(globex, tenant: "acme")
        assert reason_of(error) == :tenant_mismatch
      end)

      assert {:ok, %{overlay: overlay, log: []}} = Ramal.get(branch.id)
      assert overlay == %{}
    end

    test "reads, writes and discards without reaching the table", %{branch: branch, acme: acme} do
      Ramal.run!(branch, fn ->
        Ash.create!(Note, %{org_id: "acme", title: "a2"}, tenant: "acme")
        Ash.update!(acme, %{title: "a1b"}, tenant: "acme")
        assert titles(Ash.read!(Note, tenant: "acme")) == ["a1b", "a2"]
        assert {:error, error} = Ash.read(Note, tenant: "globex")
        assert reason_of(error) == :tenant_mismatch
      end)

      assert titles(Ash.read!(Note, tenant: "acme")) == ["a1"]
      assert titles(Ash.read!(Note, tenant: "globex")) == ["g1"]
    end

    test "merges into its tenant's rows and leaves the others alone", %{
      branch: branch,
      acme: acme
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Note, %{org_id: "acme", title: "a2"}, tenant: "acme")
        Ash.update!(acme, %{title: "a1b"}, tenant: "acme")
      end)

      assert {:ok, _result} = Ramal.merge(branch)
      assert titles(Ash.read!(Note, tenant: "acme")) == ["a1b", "a2"]
      assert titles(Ash.read!(Note, tenant: "globex")) == ["g1"]
    end

    test "merge finds a row that changed under the branch", %{branch: branch, acme: acme} do
      Ramal.run!(branch, fn -> Ash.update!(acme, %{title: "from branch"}, tenant: "acme") end)
      Ash.update!(acme, %{title: "from base"}, tenant: "acme")

      assert {:error, error} = Ramal.merge(branch)
      assert reason_of(error) == :stale
    end
  end

  describe "the context strategy (a schema for each tenant)" do
    setup do
      for tenant <- ["org_a", "org_b"],
          do: AshPostgres.MultiTenancy.create_tenant!(tenant, Ramal.TestRepo)

      a1 = Ash.create!(Plot, %{name: "a1"}, tenant: "org_a")
      Ash.create!(Plot, %{name: "b1"}, tenant: "org_b")
      {:ok, branch} = Ramal.branch(PgTenants, tenant: "org_a")
      {:ok, branch: branch, a1: a1}
    end

    test "reads and writes in its tenant's schema without reaching it", %{branch: branch, a1: a1} do
      Ramal.run!(branch, fn ->
        Ash.create!(Plot, %{name: "a2"}, tenant: "org_a")
        Ash.update!(a1, %{name: "a1b"}, tenant: "org_a")
        assert names(Ash.read!(Plot, tenant: "org_a")) == ["a1b", "a2"]
        assert {:error, error} = Ash.read(Plot, tenant: "org_b")
        assert reason_of(error) == :tenant_mismatch
      end)

      assert names(Ash.read!(Plot, tenant: "org_a")) == ["a1"]
      assert names(Ash.read!(Plot, tenant: "org_b")) == ["b1"]
    end

    test "merges into its tenant's schema and leaves the other schemas alone", %{
      branch: branch,
      a1: a1
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Plot, %{name: "a2"}, tenant: "org_a")
        Ash.update!(a1, %{name: "a1b"}, tenant: "org_a")
      end)

      assert {:ok, _result} = Ramal.merge(branch)
      assert names(Ash.read!(Plot, tenant: "org_a")) == ["a1b", "a2"]
      assert names(Ash.read!(Plot, tenant: "org_b")) == ["b1"]
    end

    test "merge finds a row that changed under the branch", %{branch: branch, a1: a1} do
      Ramal.run!(branch, fn -> Ash.update!(a1, %{name: "from branch"}, tenant: "org_a") end)
      Ash.update!(a1, %{name: "from base"}, tenant: "org_a")

      assert {:error, error} = Ramal.merge(branch)
      assert reason_of(error) == :stale
    end

    test "the same key in two schemas does not collide", %{branch: branch, a1: a1} do
      {:ok, other} = Ramal.branch(PgTenants, tenant: "org_b")

      Ramal.run!(branch, fn -> Ash.destroy!(a1, tenant: "org_a") end)
      Ramal.run!(other, fn -> assert names(Ash.read!(Plot, tenant: "org_b")) == ["b1"] end)
      assert {:ok, _result} = Ramal.merge(branch)
      assert Ash.read!(Plot, tenant: "org_a") == []
      assert names(Ash.read!(Plot, tenant: "org_b")) == ["b1"]
    end
  end
end
