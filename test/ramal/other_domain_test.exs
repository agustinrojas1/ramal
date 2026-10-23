defmodule Ramal.OtherDomainTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Test.Ets
  alias Ramal.Test.Tenanted.Shared

  setup do
    Ets.reset(Shared)
    start_supervised!(Ramal.Supervisor)
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, branch: branch}
  end

  test "a resource of another domain that uses Ramal.Resource is branched like the branch's own",
       %{
         branch: branch
       } do
    Ramal.run!(branch, fn ->
      Ash.create!(Shared, %{title: "x"})
      assert [%{title: "x"}] = Ash.read!(Shared)
    end)

    assert Ash.read!(Shared) == []
    assert {:ok, [%{resource: Shared, kind: :created}]} = Ramal.diff(branch)

    assert {:ok, _result} = Ramal.merge(branch)
    assert [%{title: "x"}] = Ash.read!(Shared)
  end
end
