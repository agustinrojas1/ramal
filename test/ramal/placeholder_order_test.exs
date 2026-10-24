defmodule Ramal.PlaceholderOrderTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Preparation.Placeholders
  alias Ramal.Test.Serial
  alias Ramal.Test.Serial.{Note, Tag}

  require Ash.Query

  setup do
    start_supervised!(Ramal.Supervisor)
    for body <- ["base 1", "base 2"], do: Ash.create!(Note, %{body: body}, authorize?: false)
    {:ok, branch} = Ramal.branch(Serial)
    {:ok, branch: branch}
  end

  defp create_new do
    for body <- ["new 1", "new 2"], do: Ash.create!(Note, %{body: body}, authorize?: false)
  end

  defp sorted(direction) do
    Note |> Ash.Query.sort(id: direction) |> Ash.read!(authorize?: false) |> Enum.map(& &1.body)
  end

  # Every page of a keyset walk by id, as lists of bodies.
  defp walk(direction, limit) do
    query = Ash.Query.sort(Note, id: direction)
    page = Ash.read!(query, action: :paged, page: [limit: limit], authorize?: false)
    walk_pages(page, [])
  end

  defp walk_pages(page, acc) do
    acc = [Enum.map(page.results, & &1.body) | acc]
    if page.more?, do: walk_pages(Ash.page!(page, :next), acc), else: Enum.reverse(acc)
  end

  # The page that ends just before the last row of the whole list.
  defp walk_before(direction, limit) do
    query = Ash.Query.sort(Note, id: direction)

    everything = Ash.read!(query, action: :paged, page: [limit: 10], authorize?: false)
    keyset = everything.results |> List.last() |> then(& &1.__metadata__.keyset)

    page =
      Ash.read!(query, action: :paged, page: [limit: limit, before: keyset], authorize?: false)

    Enum.map(page.results, & &1.body)
  end

  test "a read sorted by id ascending puts rows created in the branch last, as after the merge",
       %{branch: branch} do
    inside = Ramal.run!(branch, fn -> create_new() && sorted(:asc) end)
    assert inside == ["base 1", "base 2", "new 1", "new 2"]

    {:ok, _} = Ramal.merge(branch, authorize?: false)
    assert sorted(:asc) == inside
  end

  test "a read sorted by id descending puts rows created in the branch first, as after the merge",
       %{branch: branch} do
    inside = Ramal.run!(branch, fn -> create_new() && sorted(:desc) end)
    assert inside == ["new 2", "new 1", "base 2", "base 1"]

    {:ok, _} = Ramal.merge(branch, authorize?: false)
    assert sorted(:desc) == inside
  end

  for direction <- [:asc, :desc] do
    test "a keyset walk by id #{direction} returns the same pages in the branch and after the merge",
         %{
           branch: branch
         } do
      direction = unquote(direction)

      inside =
        Ramal.run!(branch, fn -> create_new() && {walk(direction, 3), walk(direction, 1)} end)

      assert {[[_, _, _], [_]], [[_], [_], [_], [_]]} = inside

      {:ok, _} = Ramal.merge(branch, authorize?: false)
      assert inside == {walk(direction, 3), walk(direction, 1)}
    end
  end

  test "a keyset page before a cursor returns the same rows in the branch and after the merge", %{
    branch: branch
  } do
    inside = Ramal.run!(branch, fn -> create_new() && walk_before(:asc, 2) end)
    assert inside == ["base 2", "new 1"]

    {:ok, _} = Ramal.merge(branch, authorize?: false)
    assert walk_before(:asc, 2) == inside
  end

  test "a branch that created nothing sorts the base as before", %{branch: branch} do
    assert Ramal.run!(branch, fn ->
             Note
             |> Ash.Query.sort(id: :asc)
             |> Ash.read_first!(authorize?: false)
             |> Ash.update!(%{body: "changed"}, authorize?: false)

             sorted(:asc)
           end) == ["changed", "base 2"]
  end

  test "the rows keep their placeholder keys in what the read returns", %{branch: branch} do
    ids =
      Ramal.run!(branch, fn ->
        create_new()
        Note |> Ash.Query.sort(id: :asc) |> Ash.read!(authorize?: false) |> Enum.map(& &1.id)
      end)

    assert [_, _, -2_147_483_647, -2_147_483_646] = ids
  end

  describe "Placeholders.field/1" do
    test "is the key of an integer key the database generates" do
      assert Placeholders.field(Note) == :id
    end

    test "is nil for a uuid key, whose order is not creation order" do
      assert Placeholders.field(Tag) == nil
    end
  end
end
