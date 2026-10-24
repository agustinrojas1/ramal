defmodule Ramal.AtomicRunTest do
  # `Ramal.run(branch, fun, atomic: true)` takes back the writes of `fun` when it fails. Ramal.Supervisor is one per node
  # and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [capture_branch_events: 0, crash: 1]

  alias Ramal.Branch.Server
  alias Ramal.Error
  alias Ramal.Test.Serial
  alias Ramal.Test.Serial.Note

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp atomic(branch, fun), do: Ramal.run(branch, fun, atomic: true)

  defp paddock!(attrs),
    do: Ash.create!(Paddock, Map.merge(%{capacity_head: 1}, attrs), authorize?: false)

  defp diff(branch) do
    {:ok, changes} = Ramal.diff(branch)
    changes
  end

  defp state(branch), do: elem(Ramal.get(branch.id), 1)

  defp names(branch) do
    branch
    |> Ramal.run!(fn -> Ash.read!(Paddock, authorize?: false) end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  describe "a run that raises" do
    test "leaves the branch as it was and raises the exception", %{branch: branch} do
      before = state(branch)

      assert_raise RuntimeError, "boom", fn ->
        atomic(branch, fn ->
          paddock!(%{name: "half"})
          raise "boom"
        end)
      end

      assert diff(branch) == []
      assert state(branch).overlay == before.overlay
      assert state(branch).log == before.log
      assert state(branch).base == before.base
    end

    test "keeps the writes without the option, as before", %{branch: branch} do
      assert_raise RuntimeError, fn ->
        Ramal.run!(branch, fn ->
          paddock!(%{name: "half"})
          raise "boom"
        end)
      end

      assert [_] = diff(branch)
    end

    test "raises again a throw and an exit, with the writes taken back", %{branch: branch} do
      assert :thrown ==
               catch_throw(
                 atomic(branch, fn ->
                   paddock!(%{name: "a"})
                   throw(:thrown)
                 end)
               )

      assert {:shutdown, :because} ==
               catch_exit(
                 atomic(branch, fn ->
                   paddock!(%{name: "b"})
                   exit({:shutdown, :because})
                 end)
               )

      assert diff(branch) == []
    end

    test "can be run again at once, and the run is not current afterwards", %{branch: branch} do
      assert_raise RuntimeError, fn -> atomic(branch, fn -> raise "boom" end) end
      assert Ramal.current() == nil
      assert {:ok, :fine} = atomic(branch, fn -> :fine end)
    end
  end

  describe "a run that returns" do
    test "an {:error, _} is rolled back and returned as it is", %{branch: branch} do
      assert {:ok, {:error, :no_room}} =
               atomic(branch, fn ->
                 paddock!(%{name: "half"})
                 {:error, :no_room}
               end)

      assert diff(branch) == []
    end

    test "{:ok, _} keeps the writes", %{branch: branch} do
      assert {:ok, {:ok, :done}} =
               atomic(branch, fn ->
                 paddock!(%{name: "kept"})
                 {:ok, :done}
               end)

      assert [%{kind: :created}] = diff(branch)
    end

    test "any other value keeps the writes", %{branch: branch} do
      assert {:ok, :plain} = atomic(branch, fn -> paddock!(%{name: "kept"}) && :plain end)
      assert {:ok, nil} = atomic(branch, fn -> paddock!(%{name: "kept too"}) && nil end)
      assert {:ok, :error} = atomic(branch, fn -> paddock!(%{name: "and this"}) && :error end)
      assert length(diff(branch)) == 3
    end

    test "run! returns the value and raises what the function raised", %{branch: branch} do
      assert {:error, :no} == Ramal.run!(branch, fn -> {:error, :no} end, atomic: true)

      assert_raise RuntimeError, fn ->
        Ramal.run!(branch, fn -> raise "boom" end, atomic: true)
      end
    end
  end

  describe "what the run found in the branch" do
    test "stays: only the writes of the failed run are taken back", %{
      branch: branch,
      paddocks: paddocks
    } do
      Ramal.run!(branch, fn -> paddock!(%{name: "before"}) end)

      Ramal.run!(branch, fn ->
        Ash.update!(paddocks.l07, %{capacity_head: 90}, authorize?: false)
      end)

      before = state(branch)

      assert {:ok, {:error, _}} =
               atomic(branch, fn ->
                 paddock!(%{name: "after"})
                 Ash.update!(paddocks.l07, %{capacity_head: 80}, authorize?: false)
                 Ash.update!(paddocks.l18, %{capacity_head: 10}, authorize?: false)
                 Ash.destroy!(paddocks.l07, authorize?: false)
                 {:error, :changed_my_mind}
               end)

      after_rollback = state(branch)
      assert after_rollback.overlay == before.overlay
      assert after_rollback.base == before.base
      assert after_rollback.log == before.log
      assert names(branch) == ["L07", "L18", "before"]

      assert Enum.find(
               Ramal.run!(branch, fn -> Ash.read!(Paddock, authorize?: false) end),
               &(&1.name == "L07")
             ).capacity_head == 90
    end

    test "a row the run created and destroyed leaves no trace", %{branch: branch} do
      assert {:ok, {:error, _}} =
               atomic(branch, fn ->
                 created = paddock!(%{name: "short lived"})
                 Ash.destroy!(created, authorize?: false)
                 {:error, :no}
               end)

      assert diff(branch) == []
    end
  end

  describe "a run that writes two resources" do
    test "takes back both when it raises after the second", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      assert_raise RuntimeError, fn ->
        atomic(branch, fn ->
          paddock!(%{name: "L99"})
          Ash.update!(herds.r7, %{head: 31}, authorize?: false)

          Ash.create!(
            Move,
            %{
              herd_id: herds.r7.id,
              from_paddock_id: paddocks.l07.id,
              to_paddock_id: paddocks.l18.id,
              moved_on: Date.utc_today()
            },
            authorize?: false
          )

          raise "boom"
        end)
      end

      assert diff(branch) == []
    end

    test "takes back the rows a hook of an action wrote", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      assert {:ok, {:error, :no}} =
               atomic(branch, fn ->
                 Ash.update!(herds.r9, %{to_paddock_id: paddocks.l07.id},
                   action: :move,
                   authorize?: false
                 )

                 {:error, :no}
               end)

      assert diff(branch) == []
    end

    test "keeps the earlier hook-made rows of a run that succeeds", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      assert {:ok, %{}} =
               atomic(branch, fn ->
                 Ash.update!(herds.r9, %{to_paddock_id: paddocks.l07.id},
                   action: :move,
                   authorize?: false
                 )
               end)

      assert length(diff(branch)) == 2
    end
  end

  describe "an upsert that found its row" do
    test "is taken back, and the row is as the base has it", %{branch: branch, paddocks: paddocks} do
      assert_raise RuntimeError, fn ->
        atomic(branch, fn ->
          Ash.create!(Paddock, %{name: "L07", hectares: 41.0, capacity_head: 120},
            action: :upsert,
            authorize?: false
          )

          raise "boom"
        end)
      end

      assert diff(branch) == []
      seen = Ramal.run!(branch, fn -> Ash.get!(Paddock, paddocks.l07.id, authorize?: false) end)
      assert seen.capacity_head == 100
    end

    test "is taken back to the earlier write of the branch", %{branch: branch, paddocks: paddocks} do
      Ramal.run!(branch, fn ->
        Ash.update!(paddocks.l07, %{capacity_head: 110}, authorize?: false)
      end)

      assert {:ok, {:error, :no}} =
               atomic(branch, fn ->
                 Ash.create!(Paddock, %{name: "L07", hectares: 41.0, capacity_head: 120},
                   action: :upsert,
                   authorize?: false
                 )

                 {:error, :no}
               end)

      assert [%{changes: %{capacity_head: {100, 110}}}] = diff(branch)
    end

    test "that created its row is taken back too, and a merge replays nothing of it", %{
      branch: branch
    } do
      assert {:ok, {:error, :no}} =
               atomic(branch, fn ->
                 Ash.create!(Paddock, %{name: "new", hectares: 1.0, capacity_head: 5},
                   action: :upsert,
                   authorize?: false
                 )

                 {:error, :no}
               end)

      assert {:ok, %{replayed: 0}} = Ramal.merge(branch, authorize?: false)
    end
  end

  describe "nested calls" do
    test "an atomic run inside a run is refused and the outer run still rolls back", %{
      branch: branch
    } do
      assert_raise RuntimeError, fn ->
        atomic(branch, fn ->
          paddock!(%{name: "outer"})

          assert {:error, %Error{reason: :nested_branch}} =
                   atomic(branch, fn -> paddock!(%{name: "inner"}) end)

          raise "boom"
        end)
      end

      assert diff(branch) == []
    end

    test "an action that fails inside the run takes back its own writes and the run goes on", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      assert {:ok, :done} =
               atomic(branch, fn ->
                 paddock!(%{name: "kept"})

                 # R7 and R8 together do not fit into L18, so the second move is refused and takes back its own writes.
                 {:ok, _moved} =
                   Ash.update(herds.r7, %{to_paddock_id: paddocks.l18.id},
                     action: :move,
                     authorize?: false
                   )

                 {:error, _refused} =
                   Ash.update(herds.r8, %{to_paddock_id: paddocks.l18.id},
                     action: :move,
                     authorize?: false
                   )

                 :done
               end)

      assert length(diff(branch)) == 3
    end

    test "writes of a run that failed are not seen by the next run", %{branch: branch} do
      atomic(branch, fn ->
        paddock!(%{name: "gone"})
        {:error, :no}
      end)

      assert {:ok, ["L07", "L18"]} =
               Ramal.run(branch, fn ->
                 Paddock |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()
               end)
    end
  end

  describe "a key the database generates" do
    setup do
      {:ok, branch} = Ramal.branch(Serial)
      {:ok, serial: branch}
    end

    test "is handed out again after the rollback", %{serial: branch} do
      first =
        Ramal.run!(branch, fn -> Ash.create!(Note, %{body: "kept"}, authorize?: false).id end)

      assert {:ok, {:error, :no}} =
               atomic(branch, fn ->
                 Ash.create!(Note, %{body: "a"}, authorize?: false)
                 Ash.create!(Note, %{body: "b"}, authorize?: false)
                 {:error, :no}
               end)

      assert state(branch).next_placeholder == 1

      second =
        Ramal.run!(branch, fn -> Ash.create!(Note, %{body: "next"}, authorize?: false).id end)

      assert second == first + 1
    end
  end

  describe "telemetry" do
    test "a rollback emits [:ramal, :branch, :rollback] with the entries it cut", %{
      branch: branch
    } do
      test = self()
      handler = "atomic-notifications-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ramal, :branch, :rollback],
        fn _event, _measurements, meta, _ -> send(test, {:rolled_back, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      atomic(branch, fn ->
        paddock!(%{name: "x"})
        {:error, :no}
      end)

      branch_id = branch.id
      assert_receive {:rolled_back, %{branch_id: ^branch_id, entries: 1}}
    end
  end

  describe "the branch process" do
    test "drops the savepoint of a caller that died", %{branch: branch} do
      parent = self()

      pid =
        spawn(fn ->
          {:ok, token} = Server.savepoint(branch.id)
          send(parent, {:savepoint, token})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:savepoint, token}
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert {:error, %Error{reason: :savepoint_lost}} = Server.rollback(branch.id, token)
    end

    test "answers :savepoint_lost for a branch that was restarted since", %{branch: branch} do
      {:ok, token} = Server.savepoint(branch.id)
      crash(branch.id)

      assert {:error, %Error{reason: :savepoint_lost}} = Server.rollback(branch.id, token)
    end

    test "holds no savepoint once the run has ended", %{branch: branch} do
      assert {:ok, _} = atomic(branch, fn -> paddock!(%{name: "kept"}) end)
      assert_raise RuntimeError, fn -> atomic(branch, fn -> raise "boom" end) end

      # `keep/2` is a cast, and a call after it is handled after it.
      assert [_] = diff(branch)
      assert :sys.get_state(Ramal.Supervisor.whereis(branch.id)).savepoints == %{}
    end
  end

  describe "a branch that is not open any more" do
    test "is refused before the function runs", %{branch: branch} do
      :ok = Ramal.discard(branch)
      assert {:error, %Error{reason: :not_open}} = atomic(branch, fn -> flunk("must not run") end)
    end
  end

  describe "a durable branch" do
    setup do
      {:ok, branch} = Ramal.branch(Farm, durable: true)
      {:ok, durable: branch}
    end

    test "takes back the actions that ended in the run, also after a crash", %{durable: branch} do
      Ramal.run!(branch, fn -> paddock!(%{name: "kept"}) end)
      wal = state(branch).wal

      assert_raise RuntimeError, fn ->
        atomic(branch, fn ->
          paddock!(%{name: "second"})
          paddock!(%{name: "third"})
          raise "boom"
        end)
      end

      assert [%{kind: :created}] = diff(branch)
      assert state(branch).wal > wal

      before = state(branch)
      crash(branch.id)
      recovered = state(branch)

      assert recovered.overlay == before.overlay
      assert recovered.log == before.log
      assert recovered.wal == before.wal
      assert [%{kind: :created}] = diff(branch)
    end

    test "keeps appending after a rollback, with sequence numbers not used before", %{
      durable: branch
    } do
      atomic(branch, fn ->
        paddock!(%{name: "gone"})
        {:error, :no}
      end)

      Ramal.run!(branch, fn -> paddock!(%{name: "later"}) end)
      before = state(branch)
      crash(branch.id)

      assert state(branch).overlay == before.overlay
      assert [%{kind: :created}] = diff(branch)
    end

    test "a run that wrote nothing stores nothing", %{durable: branch} do
      capture_branch_events()
      assert {:ok, {:error, :no}} = atomic(branch, fn -> {:error, :no} end)
      refute_receive {:telemetry, [:ramal, :branch, :compact], _}, 50
    end
  end
end
