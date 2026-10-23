defmodule Ramal.PaginatedReadTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use ExUnit.Case, async: false

  alias Ramal.Test.Ets
  alias Ramal.Test.Paged.Item

  setup do
    start_supervised!(Ramal.Supervisor)
    # ETS tables outlive a test, so each test starts from an empty one.
    on_exit(fn -> Ets.reset(Item) end)
    Ets.reset(Item)

    items = for n <- 1..5, do: Ash.create!(Item, %{n: n})
    {:ok, branch} = Ramal.branch(Ramal.Test.Paged)
    {:ok, %{items: items, branch: branch}}
  end

  test "resetting the table leaves no table manager behind, so the next test cannot wrap a dying one" do
    assert Ets.manager(Item)

    Ets.reset(Item)

    refute Ets.manager(Item)
  end

  defp read_all, do: Ash.read!(Item, page: [limit: 100]).results

  test "the staleness check reads every fingerprinted row, whatever the read action's default limit",
       %{
         items: items,
         branch: branch
       } do
    Ramal.run!(branch, fn -> read_all() end)
    for item <- items, do: Ash.update!(item, %{n: item.n + 100})

    assert {:error, %Ramal.Error{reason: :stale, details: %{rows: rows}}} = Ramal.merge(branch)
    assert length(rows) == 5
    assert Enum.all?(rows, &(&1.reason == :changed))
  end

  test "a merge succeeds when the primary read action requires pagination", %{
    items: [first | _],
    branch: branch
  } do
    Ramal.run!(branch, fn ->
      read_all()
      Ash.update!(first, %{n: 99})
    end)

    assert {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch)
    assert Ash.get!(Item, first.id).n == 99
  end

  test "Ramal.aggregate/4 counts and sums every row when the read action requires pagination", %{
    branch: branch
  } do
    Ramal.run!(branch, fn ->
      for n <- 10..14, do: Ash.create!(Item, %{n: n})

      assert {:ok, 10} = Ramal.aggregate(Item, :count)
      assert {:ok, 75} = Ramal.aggregate(Item, :sum, :n)
      assert {:ok, 14} = Ramal.aggregate(Item, :max, :n)
    end)
  end

  test "Ramal.aggregate/4 counts an overlay that holds more rows than the default limit", %{
    items: [first | _],
    branch: branch
  } do
    Ramal.run!(branch, fn ->
      for item <- [first], do: Ash.destroy!(item)
      for n <- 10..14, do: Ash.create!(Item, %{n: n})

      query = Ash.Query.new(Item)
      assert {:ok, 9} = Ramal.aggregate(query, :count)
    end)
  end
end
