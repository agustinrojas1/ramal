defmodule Ramal.AshIncompatibleTest do
  # With an Ash assumption broken on this node (what the boot check leaves outside the tested range, ADR 0049), a
  # branch refuses the work that relies on it with `:ash_incompatible`, and the database is not written. Outside a
  # branch nothing changes. The broken ids are one value for the node, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Ash.Contract
  alias Ramal.Error

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    on_exit(fn -> Contract.put_broken([]) end)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp break(ids), do: Contract.put_broken(ids)
  defp herd_count, do: length(Ash.read!(Herd, authorize?: false))

  describe "a core assumption is broken" do
    test "a create inside a branch is refused with :ash_incompatible and writes nothing", %{
      branch: branch
    } do
      break([:set_result_create])
      before = herd_count()

      assert {:error, error} =
               inside(branch, fn ->
                 Ash.create(Herd, %{name: "B1", head: 1}, action: :create, authorize?: false)
               end)

      assert %Error{reason: :ash_incompatible, details: %{assumption: :set_result_create}} =
               Error.find(error)

      assert herd_count() == before
    end

    test "the refusal names the assumption, the Ash version and the doctor", %{branch: branch} do
      break([:set_result_create])

      assert {:error, error} =
               inside(branch, fn ->
                 Ash.create(Herd, %{name: "B1", head: 1}, action: :create, authorize?: false)
               end)

      message = Error.find(error).message
      assert message =~ "set_result_create"
      assert message =~ "Ash #{Ramal.Ash.installed_version(:ash)}"
      assert message =~ "mix ramal.doctor"
    end

    test "a read inside a branch is refused the same way", %{branch: branch} do
      break([:set_result_create])

      assert {:error, error} =
               inside(branch, fn -> Ash.read(Herd, authorize?: false) end)

      assert %Error{reason: :ash_incompatible} = Error.find(error)
    end

    test "a create and a read outside a branch are not affected" do
      break([:set_result_create])

      assert {:ok, %Herd{name: "Outside"}} =
               Ash.create(Herd, %{name: "Outside", head: 2}, action: :create, authorize?: false)

      assert {:ok, [_ | _]} = Ash.read(Herd, authorize?: false)
    end
  end

  describe "an upsert assumption is broken" do
    test "an upsert inside a branch is refused, and a plain create in the branch still works", %{
      branch: branch,
      paddocks: %{l07: paddock}
    } do
      break([:upsert_flag])
      before = herd_count()

      assert {:error, error} =
               inside(branch, fn ->
                 Ash.create(
                   Paddock,
                   %{name: paddock.name, hectares: 1.0, capacity_head: 5},
                   action: :upsert,
                   authorize?: false
                 )
               end)

      assert %Error{reason: :ash_incompatible, details: %{feature: :upsert}} = Error.find(error)

      assert {:ok, %Herd{name: "Plain"}} =
               inside(branch, fn ->
                 Ash.create(Herd, %{name: "Plain", head: 3}, action: :create, authorize?: false)
               end)

      assert herd_count() == before
    end
  end

  describe "a bulk assumption is broken" do
    test "a bulk create inside a branch is refused, and a single create still works", %{
      branch: branch
    } do
      break([:bulk_create_around])
      before = herd_count()

      result =
        inside(branch, fn ->
          Ash.bulk_create([%{name: "B1", head: 1}], Herd, :create,
            authorize?: false,
            return_errors?: true
          )
        end)

      assert %Error{reason: :ash_incompatible, details: %{feature: :bulk}} = Error.find(result)

      assert {:ok, %Herd{name: "Single"}} =
               inside(branch, fn ->
                 Ash.create(Herd, %{name: "Single", head: 4}, action: :create, authorize?: false)
               end)

      assert herd_count() == before
    end
  end

  describe "a relationship-pages assumption is broken" do
    test "a has_many load with a limit inside a branch is refused; a load without one is not", %{
      branch: branch,
      paddocks: %{l07: paddock}
    } do
      break([:lateral_join_source])

      # A limit of 1 on one source record is a plain read in Ash (no lateral join), so the limit is 2 here.
      assert {:error, error} =
               inside(branch, fn ->
                 Ash.load(paddock, [herds: Ash.Query.limit(Herd, 2)], authorize?: false)
               end)

      assert %Error{reason: :ash_incompatible, details: %{feature: :relationship_pages}} =
               Error.find(error)

      assert {:ok, _loaded} =
               inside(branch, fn -> Ash.load(paddock, :herds, authorize?: false) end)
    end
  end
end
