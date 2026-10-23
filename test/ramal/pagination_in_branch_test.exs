defmodule Ramal.PaginationInBranchTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use ExUnit.Case, async: false

  alias Ash.Actions.Read
  alias Ramal.Resource
  alias Ramal.Test.Ets
  alias Ramal.Test.Paged.Item

  require Ash.Query

  setup do
    start_supervised!(Ramal.Supervisor)
    on_exit(fn -> Ets.reset(Item) end)
    Ets.reset(Item)

    items = for n <- 1..6, do: Ash.create!(Item, %{n: n})
    {:ok, branch} = Ramal.branch(Ramal.Test.Paged)
    {:ok, %{items: items, branch: branch}}
  end

  defp sorted, do: Ash.Query.sort(Item, n: :asc)
  defp ns(page), do: Enum.map(page.results, & &1.n)

  # Every page of an offset walk, as `{ns, count, more?}`.
  defp offset_walk(page, acc \\ []) do
    acc = [{ns(page), page.count, page.more?} | acc]

    if page.more?, do: offset_walk(Ash.page!(page, :next), acc), else: Enum.reverse(acc)
  end

  describe "offset pages" do
    test "a row created in the branch appears on the page its sort position puts it", %{
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 0})
        Ash.create!(Item, %{n: -1})

        first = Ash.read!(sorted(), page: [limit: 2, count: true])

        assert offset_walk(first) == [
                 {[-1, 0], 8, true},
                 {[1, 2], 8, true},
                 {[3, 4], 8, true},
                 {[5, 6], 8, false}
               ]
      end)
    end

    test "a deleted row shortens no page", %{items: [first, second | _], branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.destroy!(first)
        Ash.destroy!(second)

        page = Ash.read!(sorted(), page: [limit: 2, count: true])

        assert offset_walk(page) == [{[3, 4], 4, true}, {[5, 6], 4, false}]
      end)
    end

    test "a row the branch moved shows on the page of its new position", %{
      items: [first | _],
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(first, %{n: 35})

        assert offset_walk(Ash.read!(sorted(), page: [limit: 3, count: true])) ==
                 [{[2, 3, 4], 6, true}, {[5, 6, 35], 6, false}]
      end)
    end

    test "count is the patched count, and is left out when it was not asked for", %{
      items: [first | _],
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Ash.destroy!(first)
        Ash.create!(Item, %{n: 7})
        Ash.create!(Item, %{n: 8})

        assert Ash.read!(sorted(), page: [limit: 2, count: true]).count == 7
        assert Ash.read!(sorted(), page: [limit: 2]).count == nil
      end)
    end

    test "a filter narrows the pages and the count", %{branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 10})
        Ash.create!(Item, %{n: 11})

        query = sorted() |> Ash.Query.filter(n > 4)

        assert offset_walk(Ash.read!(query, page: [limit: 2, count: true])) ==
                 [{[5, 6], 4, true}, {[10, 11], 4, false}]
      end)
    end

    test "the default page of the action is patched too", %{branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 0})

        page = Ash.read!(sorted())

        assert ns(page) == [0, 1]
        assert page.more?
      end)
    end

    test "a read outside the branch is the database's page", %{branch: branch} do
      Ramal.run!(branch, fn -> Ash.create!(Item, %{n: 0}) end)

      page = Ash.read!(sorted(), page: [limit: 2, count: true])

      assert {ns(page), page.count, page.more?} == {[1, 2], 6, true}
    end

    test "a branch that did not touch the resource leaves the paging to the database", %{
      branch: branch
    } do
      page =
        Ramal.run!(branch, fn -> Ash.read!(sorted(), page: [limit: 4, offset: 4, count: true]) end)

      assert {ns(page), page.count, page.more?} == {[5, 6], 6, false}
    end
  end

  describe "reads that skip pagination" do
    test "return the whole patched list, whatever default page the action gives them", %{
      items: [first | _],
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 0})
        Ash.destroy!(first)

        # What Ash itself does for a policy check or a bulk action: the action's default_limit shows up as the query's
        # page, and the page is never applied. Nothing marks the query, so the preparation finds out afterwards.
        assert {:ok, rows} = Read.unpaginated_read(sorted(), nil, [])
        assert Enum.map(rows, & &1.n) == [0, 2, 3, 4, 5, 6]

        assert {:ok, rows} = Resource.read_all(sorted())
        assert Enum.map(rows, & &1.n) == [0, 2, 3, 4, 5, 6]
      end)
    end
  end

  describe "keyset pages" do
    defp keyset_page(query, page), do: Ash.read!(query, action: :keyset, page: page)

    defp keyset_walk(page, acc \\ []) do
      acc = [{ns(page), page.count, page.more?} | acc]

      if page.more?, do: keyset_walk(Ash.page!(page, :next), acc), else: Enum.reverse(acc)
    end

    test "after cursors walk the patched list without gaps or repeats", %{
      items: [first | _],
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 0})
        Ash.destroy!(first)
        Ash.create!(Item, %{n: 35})

        page = keyset_page(sorted(), limit: 3, count: true)

        assert %Ash.Page.Keyset{} = page
        assert Enum.all?(page.results, &is_binary(&1.__metadata__.keyset))

        assert keyset_walk(page) == [
                 {[0, 2, 3], 7, true},
                 {[4, 5, 6], 7, true},
                 {[35], 7, false}
               ]
      end)
    end

    test "before cursors walk back the same pages", %{items: [first | _], branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 0})
        Ash.destroy!(first)
        Ash.create!(Item, %{n: 35})

        last =
          keyset_page(sorted(), limit: 3, count: true) |> Ash.page!(:next) |> Ash.page!(:next)

        assert ns(last) == [35]

        middle = Ash.page!(last, :prev)
        assert {ns(middle), middle.more?} == {[4, 5, 6], true}

        first_page = Ash.page!(middle, :prev)
        assert {ns(first_page), first_page.more?} == {[0, 2, 3], false}
      end)
    end

    test "the cursor of a row the branch deleted still finds its place", %{
      items: [_, _, third | _],
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        page = keyset_page(sorted(), limit: 3)
        cursor = page.results |> List.last() |> Map.fetch!(:__metadata__) |> Map.fetch!(:keyset)
        assert ns(page) == [1, 2, 3]

        Ash.destroy!(third)

        assert ns(keyset_page(sorted(), limit: 3, after: cursor)) == [4, 5, 6]
      end)
    end

    test "a keyset read outside the branch is the database's page", %{branch: branch} do
      Ramal.run!(branch, fn -> Ash.create!(Item, %{n: 0}) end)

      page = keyset_page(sorted(), limit: 3, count: true)

      assert {ns(page), page.count, page.more?} == {[1, 2, 3], 6, true}
    end
  end

  describe "Ash.stream!" do
    test "streams every row of the patched list with offset pages", %{branch: branch} do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 0})

        rows =
          sorted()
          |> Ash.stream!(batch_size: 2, allow_stream_with: :offset)
          |> Enum.map(& &1.n)

        assert rows == [0, 1, 2, 3, 4, 5, 6]
      end)
    end

    test "streams every row of the patched list with keyset pages", %{
      items: [first | _],
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Ash.create!(Item, %{n: 0})
        Ash.destroy!(first)
        Ash.create!(Item, %{n: 35})

        rows =
          sorted()
          |> Ash.stream!(batch_size: 2, stream_with: :keyset)
          |> Enum.map(& &1.n)

        assert rows == [0, 2, 3, 4, 5, 6, 35]
      end)
    end
  end
end
