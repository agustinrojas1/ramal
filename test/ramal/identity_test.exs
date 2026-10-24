defmodule Ramal.IdentityTest do
  # A write in a branch is held to the resource's identities in the branch's view, as the database's unique indexes hold
  # it outside one. Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Invalid
  alias Ramal.Test.Bookings
  alias Ramal.Test.Bookings.Booking

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, Seeds.seed!()}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  defp create_paddock(name),
    do: Ash.create(Paddock, %{name: name, capacity_head: 1}, authorize?: false)

  # The room is part of an identity that treats nils as equal, so a booking that is not about it gets a room of its own.
  defp create_booking(attrs) do
    attrs = Map.put_new(attrs, :room, "r#{System.unique_integer([:positive])}")
    Ash.create(Booking, attrs, authorize?: false)
  end

  defp names, do: Paddock |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()

  defp taken?(
         {:error, %Invalid{errors: [%InvalidAttribute{field: field}]}},
         expected_field
       ),
       do: field == expected_field

  defp taken?(_other, _field), do: false

  describe "a create" do
    test "of a value another row holds is refused in the branch, as it is outside one", %{
      paddocks: paddocks
    } do
      outside = create_paddock(paddocks.l07.name)
      {:ok, branch} = Ramal.branch(Farm)
      inside = inside(branch, fn -> create_paddock(paddocks.l07.name) end)

      assert taken?(outside, :name)
      assert taken?(inside, :name)
      assert {:error, %Invalid{errors: [%{message: "has already been taken"}]}} = inside

      assert {:ok, []} = Ramal.diff(branch)
      assert inside(branch, &names/0) == names()
    end

    test "of a value a row created in the branch holds is refused", %{} do
      {:ok, branch} = Ramal.branch(Farm)

      inside(branch, fn ->
        assert {:ok, _} = create_paddock("N1")
        assert taken?(create_paddock("N1"), :name)
        assert {:ok, _} = create_paddock("N2")
      end)

      assert {:ok, changes} = Ramal.diff(branch)
      assert length(changes) == 2
    end

    test "of a value that is free is taken", %{} do
      {:ok, branch} = Ramal.branch(Farm)
      assert {:ok, _} = inside(branch, fn -> create_paddock("free") end)
    end

    test "of a value destroyed earlier in the same branch is taken" do
      {:ok, empty} = create_paddock("empty")
      {:ok, branch} = Ramal.branch(Farm)

      inside(branch, fn ->
        assert taken?(create_paddock("empty"), :name)
        Ash.destroy!(empty, authorize?: false)
        assert {:ok, _} = create_paddock("empty")
      end)

      assert {:ok, %{branch: %{status: :merged}}} = Ramal.merge(branch, authorize?: false)
      assert Enum.count(names(), &(&1 == "empty")) == 1
    end

    test "of a value a fork's parent holds is refused in the fork", %{paddocks: paddocks} do
      {:ok, parent} = Ramal.branch(Farm)
      inside(parent, fn -> create_paddock("from-parent") end)
      {:ok, fork} = Ramal.fork(parent)

      assert taken?(inside(fork, fn -> create_paddock("from-parent") end), :name)
      assert taken?(inside(fork, fn -> create_paddock(paddocks.l07.name) end), :name)
      assert {:ok, _} = inside(fork, fn -> create_paddock("only-in-fork") end)
    end

    test "that frees a name the parent destroyed is taken in the fork", %{paddocks: paddocks} do
      {:ok, parent} = Ramal.branch(Farm)
      inside(parent, fn -> Ash.destroy!(paddocks.l07, authorize?: false) end)
      {:ok, fork} = Ramal.fork(parent)

      assert {:ok, _} = inside(fork, fn -> create_paddock(paddocks.l07.name) end)
    end
  end

  describe "an update" do
    test "into a value another row holds is refused in the branch, as it is outside one", %{
      paddocks: paddocks
    } do
      outside = Ash.update(paddocks.l18, %{name: paddocks.l07.name}, authorize?: false)
      {:ok, branch} = Ramal.branch(Farm)

      inside =
        inside(branch, fn ->
          Ash.update(paddocks.l18, %{name: paddocks.l07.name}, authorize?: false)
        end)

      assert taken?(outside, :name)
      assert taken?(inside, :name)
      assert {:ok, []} = Ramal.diff(branch)
    end

    test "into a value that is free, or that leaves the identity alone, is taken", %{
      paddocks: paddocks
    } do
      {:ok, branch} = Ramal.branch(Farm)

      inside(branch, fn ->
        assert {:ok, _} = Ash.update(paddocks.l18, %{name: "renamed"}, authorize?: false)
        assert {:ok, _} = Ash.update(paddocks.l07, %{capacity_head: 5}, authorize?: false)
        assert {:ok, _} = Ash.update(paddocks.l07, %{name: paddocks.l07.name}, authorize?: false)
      end)
    end

    test "into the value a row had before the branch renamed it is taken", %{paddocks: paddocks} do
      {:ok, branch} = Ramal.branch(Farm)

      inside(branch, fn ->
        {:ok, renamed} = Ash.update(paddocks.l07, %{name: "moved"}, authorize?: false)
        assert {:ok, _} = Ash.update(paddocks.l18, %{name: paddocks.l07.name}, authorize?: false)
        assert taken?(Ash.update(renamed, %{name: paddocks.l07.name}, authorize?: false), :name)
      end)
    end

    test "into a value a row created in the branch holds is refused", %{paddocks: paddocks} do
      {:ok, branch} = Ramal.branch(Farm)

      inside(branch, fn ->
        {:ok, _} = create_paddock("N1")
        assert taken?(Ash.update(paddocks.l18, %{name: "N1"}, authorize?: false), :name)
      end)
    end
  end

  describe "an upsert" do
    test "on its own identity still creates or updates the row instead of being refused" do
      {:ok, branch} = Ramal.branch(Farm)

      inside(branch, fn ->
        assert {:ok, _} =
                 Ash.create(Paddock, %{name: "up", capacity_head: 1},
                   action: :upsert,
                   authorize?: false
                 )

        assert {:ok, _} =
                 Ash.create(Paddock, %{name: "up", capacity_head: 2},
                   action: :upsert,
                   authorize?: false
                 )
      end)
    end
  end

  describe "an identity with nils" do
    setup do
      {:ok, branch} = Ramal.branch(Bookings)
      {:ok, branch: branch}
    end

    test "treats nils as distinct by default", %{branch: branch} do
      inside(branch, fn ->
        assert {:ok, _} = create_booking(%{tag: nil})
        assert {:ok, _} = create_booking(%{tag: nil})
        assert {:ok, _} = create_booking(%{tag: "t"})
        assert taken?(create_booking(%{tag: "t"}), :tag)
      end)
    end

    test "treats nils as equal with `nils_distinct?: false`", %{branch: branch} do
      inside(branch, fn ->
        assert {:ok, _} = create_booking(%{room: "a", day: nil})
        assert taken?(create_booking(%{room: "a", day: nil}), :room)
        assert {:ok, _} = create_booking(%{room: "a", day: 1})
        assert {:ok, _} = create_booking(%{room: "b", day: nil})
        assert taken?(create_booking(%{room: "a", day: 1}), :room)
      end)
    end

    test "agrees with the database on a run of creates", %{branch: branch} do
      steps = [
        %{tag: nil},
        %{tag: nil},
        %{tag: "t"},
        %{tag: "t"},
        %{room: "a", day: nil},
        %{room: "a", day: nil},
        %{room: "a", day: 1},
        %{code: "c", active: true},
        %{code: "c", active: true},
        %{code: "c", active: false}
      ]

      run = fn -> Enum.map(steps, &match?({:ok, _}, create_booking(&1))) end

      outside = run.()

      for booking <- Ash.read!(Booking, authorize?: false),
          do: Ash.destroy!(booking, authorize?: false)

      assert outside == [true, true, true, false, true, false, true, true, false, true]
      assert inside(branch, run) == outside
    end

    test "treats nils as equal on an update as well", %{branch: branch} do
      inside(branch, fn ->
        {:ok, _} = create_booking(%{room: "a", day: nil})
        {:ok, other} = create_booking(%{room: "b", day: 3})
        assert taken?(Ash.update(other, %{room: "a", day: nil}, authorize?: false), :room)
      end)
    end
  end

  describe "an identity with a where" do
    setup do
      {:ok, branch} = Ramal.branch(Bookings)
      {:ok, branch: branch}
    end

    test "holds only the rows that satisfy it", %{branch: branch} do
      inside(branch, fn ->
        {:ok, first} = create_booking(%{code: "c1", active: true})

        assert {:error, %Invalid{errors: [%{message: "is in use by an active booking"}]}} =
                 create_booking(%{code: "c1"})

        assert {:ok, _} = create_booking(%{code: "c1", active: false})

        {:ok, _} = Ash.update(first, %{active: false}, authorize?: false)
        assert {:ok, _} = create_booking(%{code: "c1", active: true})
      end)
    end

    test "is checked again when an update makes a row satisfy it", %{branch: branch} do
      inside(branch, fn ->
        {:ok, _} = create_booking(%{code: "c2", active: true})
        {:ok, retired} = create_booking(%{code: "c2", active: false})
        assert taken?(Ash.update(retired, %{active: true}, authorize?: false), :code)
      end)
    end
  end
end
