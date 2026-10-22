defmodule Ramal.ProposalTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Branch
  alias Ramal.Error
  alias Ramal.Merge.Result

  @admin %{role: :admin}

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm, name: "recount")
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp reload!(herd), do: Ash.get!(Herd, herd.id, authorize?: false)
  defp db_names, do: Herd |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()

  defp proposed(%{branch: branch, herds: herds}) do
    inside(branch, fn ->
      Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
      Ash.update!(herds.r7, %{head: 31}, authorize?: false)
    end)

    {:ok, proposed} =
      Ramal.propose(branch, proposed_by: %{id: 1}, reason: "recount of the east side")

    {:ok, proposed: proposed}
  end

  describe "propose/2" do
    setup :proposed

    test "freezes the branch and records who proposed it and why", %{proposed: proposed} do
      assert proposed.status == :proposed

      assert %{proposer: %{id: 1}, reason: "recount of the east side", decision: nil} =
               proposed.proposal

      assert %DateTime{} = proposed.proposal.proposed_at
      assert {:ok, ^proposed} = Ramal.get(proposed.id)
    end

    test "refuses reads, writes, forks and a second proposal", %{proposed: proposed} do
      assert {:error, %Error{reason: :not_open}} = Ramal.run(proposed, fn -> :never end)
      assert {:error, %Error{reason: :not_open}} = Ramal.fork(proposed)
      assert {:error, %Error{reason: :not_open}} = Ramal.propose(proposed)
      assert {:error, %Error{reason: :not_open}} = Ramal.merge(proposed)
    end

    test "keeps the diff readable", %{proposed: proposed} do
      assert {:ok, changes} = Ramal.diff(proposed)
      assert Enum.sort(Enum.map(changes, & &1.kind)) == [:created, :updated]
    end

    test "is listed as proposed", %{proposed: proposed} do
      assert {:ok, [listed]} = Ramal.list(Farm, status: :proposed)
      assert listed.id == proposed.id
      assert {:ok, []} = Ramal.list(Farm, status: :open)
    end

    test "is in storage before propose/2 returns, not only in the process", %{proposed: proposed} do
      {:ok, config} = Ramal.Supervisor.config()
      assert {:ok, stored} = config.storage.fetch(proposed.id, config.storage_config)
      assert stored.status == :proposed
      assert stored.proposal == proposed.proposal
    end

    test "an open branch with nothing in it can be proposed too" do
      {:ok, empty} = Ramal.branch(Farm)
      assert {:ok, %{status: :proposed}} = Ramal.propose(empty)
    end

    test "can be withdrawn by discarding", %{proposed: proposed} do
      assert :ok = Ramal.discard(proposed)
      assert {:ok, %{status: :discarded}} = Ramal.get(proposed.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.approve(proposed)
    end
  end

  describe "approve/2" do
    setup :proposed

    test "merges the branch and records the decision", %{proposed: proposed, herds: herds} do
      assert {:ok, %Result{replayed: 2, stale: [], branch: branch}} =
               Ramal.approve(proposed,
                 decided_by: @admin,
                 reason: "checked on site",
                 authorize?: false
               )

      assert db_names() == ["R10", "R7", "R8", "R9"]
      assert reload!(herds.r7).head == 31

      assert branch.status == :merged

      assert %{status: :approved, by: @admin, reason: "checked on site", replayed: 2, stale: []} =
               branch.proposal.decision

      assert %{proposer: %{id: 1}} = branch.proposal

      assert {:ok, stored} = Ramal.get(proposed.id)
      assert stored.status == :merged
      assert stored.proposal == branch.proposal
    end

    test "passes merge options through: the actor replays the actions", %{
      herds: herds,
      paddocks: paddocks
    } do
      {:ok, branch} = Ramal.branch(Farm)

      inside(branch, fn ->
        Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)
      end)

      {:ok, proposed} = Ramal.propose(branch)

      assert {:error, %Error{reason: :merge_failed}} =
               Ramal.approve(proposed, actor: %{role: :member})

      assert {:ok, %{status: :proposed}} = Ramal.get(proposed.id)

      assert {:ok, %Result{replayed: 1}} = Ramal.approve(proposed, actor: @admin)
      assert reload!(herds.r7).paddock_id == paddocks.l18.id
    end

    test "a stale base leaves it proposed; on_stale: :ignore records the stale rows", %{
      proposed: proposed,
      herds: herds
    } do
      Ash.update!(herds.r7, %{head: 99}, authorize?: false)

      assert {:error, %Error{reason: :stale}} = Ramal.approve(proposed, authorize?: false)
      assert {:ok, %{status: :proposed, proposal: %{decision: nil}}} = Ramal.get(proposed.id)
      assert db_names() == ["R7", "R8", "R9"]

      assert {:ok, %Result{branch: branch}} =
               Ramal.approve(proposed, authorize?: false, on_stale: :ignore, decided_by: @admin)

      assert [%{key: key, reason: :changed}] = branch.proposal.decision.stale
      assert key == herds.r7.id
    end

    test "refuses a branch that is still open, and says it is not proposed" do
      {:ok, other} = Ramal.branch(Farm)
      assert {:error, %Error{reason: :not_open, message: message}} = Ramal.approve(other)
      assert message =~ "not proposed"
      assert {:ok, %{status: :open}} = Ramal.get(other.id)
    end

    test "cannot be approved twice", %{proposed: proposed} do
      assert {:ok, _} = Ramal.approve(proposed, authorize?: false)
      assert {:error, %Error{reason: :not_open}} = Ramal.approve(proposed, authorize?: false)
    end

    test "emits the approve event after the merge span", %{proposed: proposed} do
      test = self()

      :telemetry.attach_many(
        "approve-events",
        [[:ramal, :merge, :stop], [:ramal, :branch, :approve]],
        fn event, _m, meta, _ -> send(test, {:telemetry, event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("approve-events") end)

      {:ok, _} = Ramal.approve(proposed, authorize?: false)
      id = proposed.id
      assert_receive {:telemetry, [:ramal, :merge, :stop], %{result: :ok, branch_id: ^id}}
      assert_receive {:telemetry, [:ramal, :branch, :approve], %{branch_id: ^id}}
    end
  end

  describe "reject/2" do
    setup :proposed

    test "records the decision, keeps the diff and writes nothing", %{proposed: proposed} do
      assert {:ok, rejected} =
               Ramal.reject(proposed, decided_by: @admin, reason: "count it again")

      assert rejected.status == :rejected

      assert %{status: :rejected, by: @admin, reason: "count it again", replayed: nil, stale: []} =
               rejected.proposal.decision

      assert db_names() == ["R7", "R8", "R9"]

      assert {:ok, stored} = Ramal.get(proposed.id)
      assert stored == rejected
      assert {:ok, [_, _]} = Ramal.diff(proposed)
      assert {:ok, [listed]} = Ramal.list(Farm, status: :rejected)
      assert listed.id == proposed.id
    end

    test "is final", %{proposed: proposed} do
      {:ok, _} = Ramal.reject(proposed)
      assert {:error, %Error{reason: :not_open}} = Ramal.reject(proposed)
      assert {:error, %Error{reason: :not_open}} = Ramal.approve(proposed)
      assert {:error, %Error{reason: :not_open}} = Ramal.merge(proposed)
      assert {:error, %Error{reason: :not_open}} = Ramal.run(proposed, fn -> :never end)
    end

    test "refuses a branch that is not proposed" do
      {:ok, other} = Ramal.branch(Farm)
      assert {:error, %Error{reason: :not_open}} = Ramal.reject(other)
      assert {:ok, %{status: :open}} = Ramal.get(other.id)
    end

    test "emits the reject event", %{proposed: proposed} do
      test = self()

      :telemetry.attach(
        "reject-event",
        [:ramal, :branch, :reject],
        fn _event, _m, meta, _ -> send(test, {:telemetry, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("reject-event") end)

      {:ok, _} = Ramal.reject(proposed)
      id = proposed.id
      assert_receive {:telemetry, %{branch_id: ^id}}
    end
  end

  test "a branch that was never proposed has no proposal", %{branch: branch} do
    assert branch.proposal == nil
    assert Branch.open?(branch)
  end
end
