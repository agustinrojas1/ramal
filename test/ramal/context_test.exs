defmodule Ramal.ContextTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Error

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm, name: "by context")
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp names(opts),
    do:
      Herd
      |> Ash.read!(Keyword.put(opts, :authorize?, false))
      |> Enum.map(& &1.name)
      |> Enum.sort()

  test "a create with the context lands in the branch, not in the database", %{branch: branch} do
    Ash.create!(Herd, %{name: "R10", head: 5}, context: Ramal.context(branch), authorize?: false)

    assert {:ok, [%{kind: :created}]} = Ramal.diff(branch)
    assert names([]) == ["R7", "R8", "R9"]
  end

  test "a read with the context sees the base rows and what the branch changed", %{
    branch: branch,
    herds: herds
  } do
    context = Ramal.context(branch)
    Ash.create!(Herd, %{name: "R10", head: 5}, context: context, authorize?: false)
    Ash.destroy!(herds.r9, context: context, authorize?: false)

    assert names(context: context) == ["R10", "R7", "R8"]
    assert names([]) == ["R7", "R8", "R9"]
  end

  test "it accepts a branch id as well as a branch", %{branch: branch} do
    assert Ramal.context(branch.id) == Ramal.context(branch)
  end

  test "a read with the context of an unknown branch fails with not_found" do
    assert {:error, %Ash.Error.Invalid{errors: [%Error{reason: :not_found}]}} =
             Ash.read(Herd, context: Ramal.context("nope"), authorize?: false)
  end

  test "a read with the context of a proposed branch fails with not_open", %{branch: branch} do
    {:ok, proposed} = Ramal.propose(branch)

    assert {:error, %Ash.Error.Invalid{errors: [%Error{reason: :not_open}]}} =
             Ash.read(Herd, context: Ramal.context(proposed), authorize?: false)
  end

  describe "notifications" do
    alias Ramal.Test.Capture.Silent

    setup do
      Process.register(self(), :ramal_test_notifications)
      {:ok, capture: elem(Ramal.branch(Ramal.Test.Capture), 1)}
    end

    test "are sent for a write the context captured, unlike inside run/2", %{capture: branch} do
      Ramal.run!(branch, fn -> Ash.create!(Silent, %{text: "inside run"}) end)
      refute_receive {:notified, _, _}, 50

      Ash.create!(Silent, %{text: "by context"}, context: Ramal.context(branch))
      assert_receive {:notified, Silent, :create}
    end

    test "in_branch?/1 tells a notifier the write came through the context", %{capture: branch} do
      Ash.create!(Silent, %{text: "by context"}, context: Ramal.context(branch))
      assert_receive {:notified_struct, notification}
      assert Ramal.in_branch?(notification)

      Ash.create!(Silent, %{text: "in the base"})
      assert_receive {:notified_struct, base_notification}
      refute Ramal.in_branch?(base_notification)
    end
  end
end
