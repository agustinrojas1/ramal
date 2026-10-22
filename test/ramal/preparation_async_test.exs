defmodule Ramal.PreparationAsyncTest do
  # Ash only runs relationship loads in tasks outside a transaction, and the SQL sandbox wraps every test in one. This
  # test therefore commits its rows and cleans them up itself, so the branch id must reach the load through the query's
  # shared context rather than the process dictionary. See Ramal.Current.resolve/1.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ramal.Branch.Server
  alias Ramal.{Overlay, TestRepo}
  alias Ramal.Test.Farm
  alias Ramal.Test.Farm.{Herd, Move, Paddock}

  setup do
    Sandbox.mode(TestRepo, :auto)
    start_supervised!(Ramal.Supervisor)

    on_exit(fn ->
      TestRepo.delete_all(Move)
      TestRepo.delete_all(Herd)
      TestRepo.delete_all(Paddock)
      Sandbox.mode(TestRepo, :manual)
    end)

    paddock = Ash.create!(Paddock, %{name: "L01", capacity_head: 50}, authorize?: false)
    herd = Ash.create!(Herd, %{name: "base", head: 5, paddock_id: paddock.id}, authorize?: false)
    {:ok, branch} = Ramal.branch(Farm)
    %{branch: branch, paddock: paddock, herd: herd}
  end

  # Ash builds a load's first-level queries in the calling process, so their hooks already know the branch. The queries
  # for the levels below are built inside the task that runs the first level, where the process dictionary is empty.
  # Loading two relationships that each lead back to herds makes one of those nested queries be built in a task.
  test "a nested relationship load that Ash runs in a task is patched with the branch's changes",
       ctx do
    Ash.create!(
      Move,
      %{herd_id: ctx.herd.id, to_paddock_id: ctx.paddock.id, moved_on: ~D[2026-01-01]},
      authorize?: false
    )

    {:ok, _} =
      Server.update(ctx.branch.id, fn b ->
        %{
          b
          | overlay:
              Overlay.put_updated(b.overlay, {Herd, ctx.herd.id}, %{ctx.herd | name: "renamed"})
        }
      end)

    for load <- [[paddock: :herds, moves: :herd], [moves: :herd, paddock: :herds]] do
      [herd] =
        Ramal.run!(ctx.branch, fn ->
          Herd |> Ash.Query.load(load) |> Ash.read!(authorize?: false)
        end)

      assert herd.name == "renamed"
      assert Enum.map(herd.paddock.herds, & &1.name) == ["renamed"]
      assert [%{herd: %{name: "renamed"}}] = herd.moves
    end
  end
end
