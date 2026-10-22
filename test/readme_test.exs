defmodule Ramal.ReadmeTest do
  # Ramal.Supervisor is one per node and named, so this test cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Change

  @readme Path.join(__DIR__, "../README.md")

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, Seeds.seed!()}
  end

  # The first Elixir block of the README is the example. Only the host's module prefix is swapped for the test domain's;
  # the variables the example uses (`herd`, `paddock`, `admin`) are bound to fixtures.
  defp example do
    [_, code] = Regex.run(~r/```elixir\n(.*?)```/s, File.read!(@readme))
    assert code =~ "Ramal.branch(MyApp.Farm"
    String.replace(code, "MyApp.Farm", "Ramal.Test.Farm")
  end

  test "the example in the README runs as written", %{herds: herds, paddocks: paddocks} do
    binding = [herd: herds.r7, paddock: paddocks.l18, admin: %{role: :admin}]

    {_result, bound} = Code.eval_string(example(), binding)

    assert [%Change{resource: Herd, kind: :updated} = change] = bound[:changes]
    assert change.key == herds.r7.id
    # The update timestamp changes with the row, so it is in the diff too.
    assert change.changes.paddock_id == {paddocks.l07.id, paddocks.l18.id}
    assert change.changes |> Map.keys() |> Enum.sort() == [:paddock_id, :updated_at]

    assert %Ramal.Merge.Result{replayed: 1, stale: []} = bound[:merged]
    assert Ash.get!(Herd, herds.r7.id, authorize?: false).paddock_id == paddocks.l18.id

    assert {:ok, %{status: :merged}} = Ramal.get(bound[:branch].id)
    assert {:ok, %{status: :discarded}} = Ramal.get(bound[:copy].id)
  end

  test "the proposal example in the README runs as written", %{herds: herds, paddocks: paddocks} do
    # The second Elixir block of the README is the proposal example.
    [_first, [code] | _others] =
      Regex.scan(~r/```elixir\n(.*?)```/s, File.read!(@readme), capture: :all_but_first)

    code = String.replace(code, "MyApp.Farm", "Ramal.Test.Farm")

    binding = [
      herd: herds.r7,
      paddock: paddocks.l18,
      agent: %{id: "agent-1"},
      manager: %{role: :admin}
    ]

    {_result, bound} = Code.eval_string(code, binding)

    assert [%{status: :proposed}] = bound[:pending]
    assert [%Change{kind: :updated}] = bound[:changes]
    assert %Ramal.Merge.Result{branch: %{status: :merged} = branch} = bound[:result]
    assert branch.proposal.decision.by == %{role: :admin}
    assert Ash.get!(Herd, herds.r7.id, authorize?: false).paddock_id == paddocks.l18.id
  end

  test "the read in the example sees the branch's change", %{herds: herds, paddocks: paddocks} do
    binding = [herd: herds.r7, paddock: paddocks.l18, admin: %{role: :admin}]
    code = example() |> String.split("{:ok, copy}") |> hd()

    {read, _bound} = Code.eval_string(code, binding)

    assert Enum.find(read, &(&1.id == herds.r7.id)).paddock_id == paddocks.l18.id
    assert Ash.get!(Herd, herds.r7.id, authorize?: false).paddock_id == paddocks.l07.id
  end
end
