defmodule Ramal.GeneratedKeyTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Merge.Result
  alias Ramal.Storage.Codec
  alias Ramal.Test.Serial
  alias Ramal.Test.Serial.{Note, Tag}

  @first -2_147_483_647

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, branch} = Ramal.branch(Serial)
    {:ok, branch: branch}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp note!(attrs), do: Ash.create!(Note, attrs, authorize?: false)
  defp tag!(attrs), do: Ash.create!(Tag, attrs, authorize?: false)
  defp base_notes, do: Note |> Ash.read!(authorize?: false) |> Enum.sort_by(& &1.id)

  defp diff(branch) do
    {:ok, changes} = Ramal.diff(branch)
    changes
  end

  describe "a create whose key the database generates" do
    test "gets a placeholder key in the branch and writes nothing", %{branch: branch} do
      note = inside(branch, fn -> note!(%{body: "first"}) end)

      assert note.id == @first
      assert base_notes() == []
      assert [%{kind: :created, key: @first}] = diff(branch)
    end

    test "gets a different placeholder each time", %{branch: branch} do
      ids = inside(branch, fn -> for body <- ~w(a b c), do: note!(%{body: body}).id end)
      assert ids == [@first, @first + 1, @first + 2]
    end

    test "is read by key, in a list and through a filter in the branch", %{branch: branch} do
      inside(branch, fn ->
        note = note!(%{body: "first"})
        assert Ash.get!(Note, note.id, authorize?: false).body == "first"
        assert [%{id: id}] = Ash.read!(Note, authorize?: false)
        assert id == note.id
        require Ash.Query
        assert [_] = Note |> Ash.Query.filter(id == ^note.id) |> Ash.read!(authorize?: false)
      end)
    end

    test "can be updated in the branch", %{branch: branch} do
      inside(branch, fn ->
        note = note!(%{body: "first"})
        updated = Ash.update!(note, %{body: "second"}, authorize?: false)
        assert updated.id == note.id
        assert Ash.get!(Note, note.id, authorize?: false).body == "second"
      end)

      assert [%{kind: :created, changes: %{body: {nil, "second"}}}] = diff(branch)
    end

    test "can be destroyed in the branch, leaving nothing to merge", %{branch: branch} do
      inside(branch, fn ->
        note = note!(%{body: "first"})
        Ash.destroy!(note, authorize?: false)
      end)

      assert diff(branch) == []
      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      assert base_notes() == []
    end
  end

  describe "merging" do
    test "writes the row with the key the database gave it", %{branch: branch} do
      note = inside(branch, fn -> note!(%{body: "first"}) end)
      real_before = base_notes()

      assert {:ok, %Result{replayed: 1, keys: keys, records: records}} =
               Ramal.merge(branch, authorize?: false)

      assert real_before == []
      assert [%{id: real, body: "first"}] = base_notes()
      assert real > 0
      assert keys == %{{Note, note.id} => real}
      assert {:created, %{id: ^real}} = records[{Note, real}]
      refute Map.has_key?(records, {Note, note.id})
    end

    test "gives a row that refers to it by a param the real key", %{branch: branch} do
      inside(branch, fn ->
        parent = note!(%{body: "parent"})
        note!(%{body: "child", parent_id: parent.id})
      end)

      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      [parent, child] = base_notes()
      assert parent.body == "parent"
      assert child.parent_id == parent.id
      assert parent.id > 0
    end

    test "renames a key given as text, as a form sends it", %{branch: branch} do
      inside(branch, fn ->
        parent = note!(%{body: "parent"})
        note!(%{"body" => "child", "parent_id" => Integer.to_string(parent.id)})
      end)

      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      [parent, child] = base_notes()
      assert child.parent_id == parent.id
    end

    test "applies an update of a placeholder row to the real row", %{branch: branch} do
      inside(branch, fn ->
        note = note!(%{body: "first"})
        Ash.update!(note, %{body: "second"}, authorize?: false)
      end)

      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)
      assert [%{body: "second"}] = base_notes()
    end

    test "leaves rows the base already had alone", %{branch: branch} do
      existing = note!(%{body: "existing"})
      inside(branch, fn -> note!(%{body: "new"}) end)

      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      assert [%{id: id, body: "existing"}, %{body: "new", id: new}] = base_notes()
      assert id == existing.id
      assert new > id
    end

    test "works for a uuid key the database generates", %{branch: branch} do
      {tag, note} =
        inside(branch, fn ->
          tag = tag!(%{label: "red"})
          {tag, note!(%{body: "tagged", tag_id: tag.id})}
        end)

      assert {:ok, uuid} = Ecto.UUID.cast(tag.id)
      assert note.tag_id == uuid
      assert Ash.read!(Tag, authorize?: false) == []

      assert {:ok, %Result{keys: %{{Tag, ^uuid} => real}}} =
               Ramal.merge(branch, authorize?: false)

      assert real != uuid
      assert [%{label: "red", id: ^real}] = Ash.read!(Tag, authorize?: false)
      assert [%{tag_id: ^real}] = base_notes()
    end
  end

  describe "bulk creates" do
    test "give each record its own placeholder, and the merge renames each", %{branch: branch} do
      notes =
        inside(branch, fn ->
          Ash.bulk_create([%{body: "one"}, %{body: "two"}, %{body: "three"}], Note, :create,
            authorize?: false,
            return_errors?: true,
            return_records?: true
          ).records
        end)

      placeholders = notes |> Enum.map(& &1.id) |> Enum.sort()
      assert length(Enum.uniq(placeholders)) == 3
      assert Enum.all?(placeholders, &(&1 < 0))
      assert base_notes() == []

      assert {:ok, %Result{replayed: 3, keys: keys}} = Ramal.merge(branch, authorize?: false)
      assert keys |> Map.keys() |> Enum.sort() == Enum.map(placeholders, &{Note, &1})
      assert base_notes() |> Enum.map(& &1.body) |> Enum.sort() == ["one", "three", "two"]

      assert base_notes() |> Enum.map(& &1.id) |> Enum.sort() ==
               keys |> Map.values() |> Enum.sort()
    end

    test "rename the key a later action refers to", %{branch: branch} do
      inside(branch, fn ->
        [parent] =
          Ash.bulk_create([%{body: "parent"}], Note, :create,
            authorize?: false,
            return_records?: true
          ).records

        note!(%{body: "child", parent_id: parent.id})
      end)

      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch, authorize?: false)

      assert [%{id: parent_id, body: "parent"}, %{body: "child", parent_id: child_parent}] =
               base_notes()

      assert child_parent == parent_id
    end
  end

  describe "upserts" do
    defp upsert!(code, body, parent_id \\ nil),
      do:
        Ash.create!(Note, %{code: code, body: body, parent_id: parent_id},
          action: :upsert,
          authorize?: false
        )

    test "of a row the base has take its key and hand out no placeholder", %{branch: branch} do
      existing = note!(%{body: "known", code: "k"})

      found = inside(branch, fn -> upsert!("k", "known again", existing.id) end)

      assert found.id == existing.id
      assert {:ok, %Result{keys: keys}} = Ramal.merge(branch, authorize?: false)
      assert keys == %{}
      assert [%{id: id, parent_id: parent, body: "known again"}] = base_notes()
      assert id == existing.id
      assert parent == existing.id
    end

    test "of a missing row get a placeholder that the merge renames", %{branch: branch} do
      created = inside(branch, fn -> upsert!("f", "fresh") end)

      assert created.id < 0
      assert {:ok, %Result{replayed: 1, keys: keys}} = Ramal.merge(branch, authorize?: false)
      assert [%{id: real, body: "fresh"}] = base_notes()
      assert keys == %{{Note, created.id} => real}
    end

    test "of a row the branch created with a placeholder update it, and the merge writes one row",
         %{
           branch: branch
         } do
      {first, second} =
        inside(branch, fn ->
          first = upsert!("s", "same")
          parent = note!(%{body: "parent"})
          {first, upsert!("s", "same again", parent.id)}
        end)

      assert second.id == first.id

      assert {:ok, %Result{replayed: 3, keys: keys}} = Ramal.merge(branch, authorize?: false)
      assert map_size(keys) == 2

      assert [%{body: "same again", parent_id: same_parent}, %{id: parent_id, body: "parent"}] =
               base_notes()

      assert same_parent == parent_id

      assert keys[{Note, first.id}] != nil
    end
  end

  describe "forks" do
    test "keep their own placeholders and each is renamed at its own merge", %{branch: branch} do
      inside(branch, fn -> note!(%{body: "parent"}) end)
      {:ok, a} = Ramal.fork(branch)
      {:ok, b} = Ramal.fork(branch)

      a_note = inside(a, fn -> note!(%{body: "a"}) end)
      b_note = inside(b, fn -> note!(%{body: "b"}) end)
      assert a_note.id == b_note.id

      assert {:ok, %Result{}} = Ramal.merge(a, authorize?: false)
      assert {:ok, %Result{}} = Ramal.merge(b, authorize?: false, on_stale: :ignore)
      assert base_notes() |> Enum.map(& &1.body) |> Enum.sort() == ["a", "b", "parent", "parent"]
    end
  end

  describe "storage" do
    test "the counter survives an unload, so no placeholder repeats" do
      {:ok, branch} = Ramal.branch(Serial)
      first = inside(branch, fn -> note!(%{body: "a"}) end)

      {:ok, state} = Ramal.get(branch.id)
      {:ok, encoded} = Codec.encode_state(state)
      encoded = encoded |> Jason.encode!() |> Jason.decode!()

      columns = %{
        id: state.id,
        domain: Atom.to_string(state.domain),
        name: state.name,
        status: "open"
      }

      assert {:ok, restored} = Codec.decode_state(columns, encoded)
      assert restored.next_placeholder == state.next_placeholder
      assert restored.next_placeholder > 0
      assert first.id == @first
    end

    test "a state stored without the counter loads with it at zero" do
      {:ok, state} = Ramal.branch(Serial)
      {:ok, encoded} = Codec.encode_state(state)
      encoded = Map.delete(encoded, "next_placeholder")

      columns = %{id: state.id, domain: Atom.to_string(state.domain), name: nil, status: "open"}
      assert {:ok, %{next_placeholder: 0}} = Codec.decode_state(columns, encoded)
    end
  end
end
