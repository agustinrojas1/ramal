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
  defp in_transaction(:ash, fun), do: Ash.transact(Herd, fun)
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
end
