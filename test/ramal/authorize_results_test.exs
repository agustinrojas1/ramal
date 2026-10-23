defmodule Ramal.AuthorizeResultsTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Test.Farm.Paddock

  # `Herd`'s `:checked` read action has a policy whose check only runs on the rows the read returned
  # (`Ramal.Test.Farm.Checks.SmallHerd`): it drops every herd with more than 100 head, as it does outside a branch.

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, %{branch: branch}}
  end

  defp checked(query \\ Herd, opts \\ []) do
    names = query |> Ash.read!([action: :checked] ++ opts) |> Enum.map(& &1.name)
    Enum.sort(names)
  end

  defp seed do
    for {name, head} <- [{"small", 10}, {"big", 200}] do
      Ash.create!(Herd, %{name: name, head: head}, authorize?: false)
    end
  end

  test "the check drops a base row outside a branch" do
    seed()
    assert checked() == ["small"]
  end

  test "a read inside a branch applies the check to rows the branch created" do
    seed()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "new small", head: 20}, authorize?: false)
      Ash.create!(Herd, %{name: "new big", head: 300}, authorize?: false)

      assert checked() == ["new small", "small"]
    end)
  end

  test "a read inside a branch applies the check to a row the branch changed" do
    [small, _big] = seed()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.update!(small, %{head: 150}, authorize?: false)
      assert checked() == []
    end)

    Ramal.run!(branch, fn ->
      Herd
      |> Ash.Query.filter(name == "big")
      |> Ash.read_one!(authorize?: false)
      |> Ash.update!(%{head: 5}, authorize?: false)

      assert checked() == ["big"]
    end)
  end

  test "the check runs on the patched rows of a filtered, sorted and limited read (the limit comes first, as in the database)" do
    seed()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "a big", head: 300}, authorize?: false)
      Ash.create!(Herd, %{name: "b small", head: 30}, authorize?: false)

      query = Herd |> Ash.Query.sort(:name) |> Ash.Query.filter(head >= 30) |> Ash.Query.limit(2)
      assert checked(query) == ["b small"]
    end)
  end

  test "a paged read applies the check to the rows of its page" do
    seed()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "a big", head: 300}, authorize?: false)
      Ash.create!(Herd, %{name: "b small", head: 30}, authorize?: false)

      page =
        Herd
        |> Ash.Query.for_read(:checked)
        |> Ash.Query.sort(:name)
        |> Ash.read!(page: [limit: 2, offset: 0, count: true])

      # The page is cut from the patched list, then checked, as the database pages and then checks.
      assert Enum.map(page.results, & &1.name) == ["b small"]
      assert page.count == 4
    end)
  end

  test "a read of a resource the branch did not touch is unchanged" do
    seed()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Paddock, %{name: "North", capacity_head: 10}, authorize?: false)
      assert checked() == ["small"]
    end)
  end

  test "the same read outside the branch does not see the branch's rows" do
    seed()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "new small", head: 20}, authorize?: false)
    end)

    assert checked() == ["small"]
  end

  test "a relationship load through the action reads the check's rows too" do
    paddock = Ash.create!(Paddock, %{name: "North", capacity_head: 500}, authorize?: false)
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      for {name, head} <- [{"s", 10}, {"b", 400}] do
        Ash.create!(Herd, %{name: name, head: head, paddock_id: paddock.id}, authorize?: false)
      end

      loaded =
        Paddock
        |> Ash.Query.load(herds: Ash.Query.for_read(Herd, :checked))
        |> Ash.read_one!(authorize?: false)

      assert Enum.map(loaded.herds, & &1.name) == ["s"]
    end)
  end
end
