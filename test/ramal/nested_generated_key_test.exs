defmodule Ramal.NestedGeneratedKeyTest do
  # A nested fork (ADR 0043) replays its entries in a scratch copy of the parent, so the rows whose key the database
  # generates (ADR 0042) get a placeholder of the parent's, and the merge to the database renames that one.
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Test.Serial
  alias Ramal.Test.Serial.Note

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, parent} = Ramal.branch(Serial, name: "parent")
    {:ok, child} = Ramal.fork(parent, nested: true, name: "child")
    {:ok, parent: parent, child: child}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp note!(attrs), do: Ash.create!(Note, attrs, authorize?: false)
  defp notes_in(branch), do: inside(branch, fn -> Ash.read!(Note, authorize?: false) end)
  defp base_notes, do: Note |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.id)

  test "a fork's created rows reach the parent and then the database under real keys", %{
    parent: parent,
    child: child
  } do
    inside(parent, fn -> note!(%{body: "parent's"}) end)

    inside(child, fn ->
      first = note!(%{body: "first"})
      note!(%{body: "second", parent_id: first.id})
    end)

    assert {:ok, %{replayed: 2}} = Ramal.merge(child, authorize?: false)

    in_parent = notes_in(parent)
    assert length(in_parent) == 3
    assert in_parent |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3
    assert Enum.all?(in_parent, &(&1.id < 0))
    assert %{id: first_id} = Enum.find(in_parent, &(&1.body == "first"))
    assert Enum.find(in_parent, &(&1.body == "second")).parent_id == first_id
    assert base_notes() == []

    assert {:ok, %{replayed: 3}} = Ramal.merge(parent, authorize?: false)

    assert [%{body: "parent's"}, %{body: "first", id: first}, %{body: "second", parent_id: ref}] =
             base_notes()

    assert ref == first
  end

  test "the parent keeps handing out placeholders that do not repeat one it adopted", %{
    parent: parent,
    child: child
  } do
    inside(child, fn -> note!(%{body: "from the fork"}) end)
    assert {:ok, %{replayed: 1}} = Ramal.merge(child, authorize?: false)

    inside(parent, fn -> note!(%{body: "after the adoption"}) end)

    ids = parent |> notes_in() |> Enum.map(& &1.id)
    assert length(Enum.uniq(ids)) == 2
  end

  test "a row a hook creates in the fork is found by a later action when it is merged", %{
    parent: parent,
    child: child
  } do
    existing = Ash.create!(Note, %{body: "base"}, authorize?: false)

    inside(child, fn ->
      Ash.update!(existing, %{}, action: :annotate, authorize?: false)
      annotation = Note |> Ash.read!(authorize?: false) |> Enum.find(&(&1.body == "annotation"))
      Ash.update!(annotation, %{body: "edited"}, authorize?: false)
    end)

    assert {:ok, %{replayed: 2}} = Ramal.merge(child, authorize?: false)
    assert parent |> notes_in() |> Enum.map(& &1.body) |> Enum.sort() == ["base", "edited"]

    assert {:ok, %{replayed: 2}} = Ramal.merge(parent, authorize?: false)
    assert [%{body: "base"}, %{body: "edited", parent_id: parent_id}] = base_notes()
    assert parent_id == existing.id
  end

  test "bulk creates and upserts in the fork are replayed in the parent and then in the database",
       %{
         parent: parent,
         child: child
       } do
    existing = Ash.create!(Note, %{body: "known", code: "k"}, authorize?: false)

    inside(child, fn ->
      Ash.bulk_create!([%{body: "one"}, %{body: "two"}], Note, :create, authorize?: false)

      for {code, body} <- [{"k", "known again"}, {"n", "new"}] do
        Ash.create!(Note, %{code: code, body: body}, action: :upsert, authorize?: false)
      end
    end)

    assert {:ok, %{replayed: 4}} = Ramal.merge(child, authorize?: false)

    assert parent |> notes_in() |> Enum.map(& &1.body) |> Enum.sort() == [
             "known again",
             "new",
             "one",
             "two"
           ]

    assert {:ok, %{replayed: 4}} = Ramal.merge(parent, authorize?: false)

    assert base_notes() |> Enum.map(& &1.body) |> Enum.sort() == [
             "known again",
             "new",
             "one",
             "two"
           ]

    assert Enum.find(base_notes(), &(&1.body == "known again")).id == existing.id
  end
end
