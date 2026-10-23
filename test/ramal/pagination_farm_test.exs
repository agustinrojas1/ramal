defmodule Ramal.PaginationFarmTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp list(page, opts \\ []), do: list(Herd, page, opts)

  defp list(query, page, opts) do
    Ash.read!(
      Ash.Query.sort(query, name: :asc),
      [action: :list, page: page, authorize?: false] ++ opts
    )
  end

  defp names(page), do: Enum.map(page.results, & &1.name)

  test "relationships and calculations load onto the rows of the page, the branch's included", %{
    branch: branch,
    paddocks: p
  } do
    Ramal.run!(branch, fn ->
      Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)
      Ash.create!(Herd, %{name: "R0", head: 31, paddock_id: p.l18.id}, authorize?: false)

      page = list([limit: 2, count: true], load: [:paddock, :size])

      assert names(page) == ["R0", "R7"]
      assert page.count == 4
      assert Enum.map(page.results, & &1.size) == ["large", "large"]
      assert Enum.map(page.results, & &1.paddock.name) == ["L18", "RENAMED"]
    end)
  end

  test "a filter through a relationship the branch renamed pages the branch's rows", %{
    branch: branch,
    paddocks: p
  } do
    Ramal.run!(branch, fn ->
      Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)
      Ash.update!(p.l18, %{name: "L07"}, authorize?: false)

      page = list(Ash.Query.filter(Herd, paddock.name == "RENAMED"), [limit: 1, count: true], [])

      assert {names(page), page.count, page.more?} == {["R7"], 2, true}
      assert names(Ash.page!(page, :next)) == ["R8"]
    end)
  end

  test "the actor's policies still apply to the rows of the page", %{branch: branch} do
    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "R0", head: 10}, authorize?: false)

      page =
        Ash.read!(Ash.Query.sort(Herd, name: :asc),
          action: :list,
          page: [limit: 2, count: true],
          actor: %{role: :admin}
        )

      assert {names(page), page.count} == {["R0", "R7"], 4}
    end)
  end

  test "a sort on a calculation pages the branch's rows", %{branch: branch, herds: h} do
    Ramal.run!(branch, fn ->
      Ash.update!(h.r9, %{head: 99}, authorize?: false)
      Ash.create!(Herd, %{name: "R0", head: 31}, authorize?: false)

      page =
        Herd
        |> Ash.Query.sort(size: :desc, name: :asc)
        |> Ash.read!(action: :list, page: [limit: 3, count: true], authorize?: false)

      assert names(page) == ["R0", "R7", "R8"]
      assert Ash.page!(page, :next).results |> Enum.map(& &1.name) == ["R9"]
    end)
  end

  test "a destroyed base row does not come back through a later page", %{branch: branch, herds: h} do
    Ramal.run!(branch, fn ->
      Ash.destroy!(h.r8, authorize?: false)

      page = list(limit: 1, count: true)

      assert {names(page), page.count} == {["R7"], 2}
      assert names(Ash.page!(page, :next)) == ["R9"]
    end)
  end

  test "the rows a page returned are fingerprinted, so a base change is found at merge", %{
    branch: branch,
    herds: h
  } do
    Ramal.run!(branch, fn -> list(limit: 3) end)
    Ash.update!(h.r7, %{head: 1}, authorize?: false)

    assert {:error, %Ramal.Error{reason: :stale}} = Ramal.merge(branch)
  end
end
