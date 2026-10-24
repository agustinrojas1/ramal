defmodule Ramal.MergeSavepointTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Error

  @admin %{role: :admin}

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp herd_names, do: Herd |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()

  defp in_transaction(:repo, fun), do: Ramal.TestRepo.transaction(fun)
  defp in_transaction(:ash, fun), do: Ash.transact([Herd, Ramal.Test.Named.NamedPaddock], fun)
  defp repo_transaction(fun), do: in_transaction(:repo, fun)

  describe "a refused merge inside the caller's transaction" do
    setup %{branch: branch, herds: herds, paddocks: paddocks} do
      Ramal.run!(branch, fn ->
        Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)
      end)

      :ok
    end

    for {name, wrap} <- [{"Repo.transaction", :repo}, {"Ash.transact", :ash}] do
      test "a failed replay under #{name} returns the error and keeps the caller's writes", %{
        branch: branch,
        paddocks: paddocks
      } do
        Ash.create!(Herd, %{name: "R11", head: 10, paddock_id: paddocks.l18.id},
          authorize?: false
        )

        Ash.create!(Herd, %{name: "R12", head: 10, paddock_id: paddocks.l18.id},
          authorize?: false
        )

        assert {:ok, {:done, {:error, %Error{reason: :merge_failed}}}} =
                 in_transaction(unquote(wrap), fn -> after_call(branch) end)

        assert "BEFORE" in herd_names()
        assert "AFTER" in herd_names()
        assert {:ok, %{status: :open}} = Ramal.get(branch.id)
      end

      test "a stale refusal under #{name} returns the error and keeps the caller's writes", %{
        branch: branch,
        herds: herds
      } do
        Ash.update!(herds.r7, %{head: 99}, authorize?: false)

        assert {:ok, {:done, {:error, %Error{reason: :stale}}}} =
                 in_transaction(unquote(wrap), fn -> after_call(branch) end)

        assert "BEFORE" in herd_names()
        assert "AFTER" in herd_names()
        assert {:ok, %{status: :open}} = Ramal.get(branch.id)
      end
    end

    test "a merge that succeeds inside the caller's transaction commits with it", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      assert {:ok, {:ok, %Ramal.Merge.Result{replayed: 1}}} =
               repo_transaction(fn ->
                 Ash.create!(Herd, %{name: "BEFORE", head: 1}, authorize?: false)
                 Ramal.merge(branch)
               end)

      assert "BEFORE" in herd_names()
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).paddock_id == paddocks.l18.id
    end

    test "the caller's rollback after a successful merge takes the merge back", %{
      branch: branch,
      herds: herds
    } do
      assert {:error, :abort} =
               repo_transaction(fn ->
                 assert {:ok, _} = Ramal.merge(branch)
                 Ramal.TestRepo.rollback(:abort)
               end)

      assert Ash.get!(Herd, herds.r7.id, authorize?: false).paddock_id == herds.r7.paddock_id
    end
  end

  defp after_call(branch) do
    Ash.create!(Herd, %{name: "BEFORE", head: 1}, authorize?: false)
    result = Ramal.merge(branch, on_stale: :error)
    Ash.create!(Herd, %{name: "AFTER", head: 1}, authorize?: false)
    {:done, result}
  end

  describe "a replayed write the database refuses with a constraint Ash does not map" do
    alias Ramal.Test.Named
    alias Ramal.Test.Named.NamedPaddock

    # The branch makes "K2" with a key it chose; another writer takes the key before the merge.
    setup do
      {:ok, branch} = Ramal.branch(Named)
      Ramal.run!(branch, fn -> Ash.create!(NamedPaddock, %{name: "K2", capacity_head: 1}) end)
      Ash.create!(NamedPaddock, %{name: "K2", capacity_head: 2}, authorize?: false)
      {:ok, taken: branch}
    end

    defp paddock_names,
      do:
        NamedPaddock
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.name)
        |> Enum.sort()
        |> Kernel.--(["L07", "L18"])

    test "returns an error that names the key and the constraint, and leaves the branch open", %{
      taken: branch
    } do
      assert {:error, %Error{reason: :merge_failed, details: details}} =
               Ramal.merge(branch, on_stale: :ignore)

      assert %{constraint: "paddocks_unique_name_index", resource: NamedPaddock, key: "K2"} =
               details

      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
      assert paddock_names() == ["K2"]
    end

    for {name, wrap} <- [{"Repo.transaction", :repo}, {"Ash.transact", :ash}] do
      test "under #{name} it returns, keeps the caller's writes and runs the code after the call",
           %{
             taken: branch
           } do
        wrapped =
          in_transaction(unquote(wrap), fn ->
            Ash.create!(NamedPaddock, %{name: "BEFORE", capacity_head: 1}, authorize?: false)
            result = Ramal.merge(branch, on_stale: :ignore)
            Ash.create!(NamedPaddock, %{name: "AFTER", capacity_head: 1}, authorize?: false)
            {:done, result}
          end)

        assert {:ok, {:done, {:error, %Error{reason: :merge_failed, details: %{key: "K2"}}}}} =
                 wrapped

        assert paddock_names() == ["AFTER", "BEFORE", "K2"]
        assert {:ok, %{status: :open}} = Ramal.get(branch.id)
      end
    end
  end
end
