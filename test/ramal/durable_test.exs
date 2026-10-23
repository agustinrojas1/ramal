defmodule Ramal.DurableTest do
  # Durable branches (ADR 0048): the writes of every action that ended are in the storage's write log before the
  # action returns, so a branch process that dies loses none of them. Ramal.Supervisor is one per node and named, so
  # these tests cannot run concurrently.
  use Ramal.BranchCase, async: false

  alias Ramal.Storage.ETS
  alias Ramal.Test.Capture
  alias Ramal.Test.Capture.{Flaky, Gated, Silent}
  alias Ramal.Test.DurableStorage

  @moduletag supervisor: [storage: DurableStorage]

  # The deltas the storage holds for the branch, as `{seq, delta}`.
  defp deltas(id),
    do:
      elem(
        ETS.writes_after(%Branch{id: id, domain: Capture, inserted_at: DateTime.utc_now()}, []),
        1
      )

  defp state(id), do: elem(Ramal.get(id), 1)

  defp texts(branch),
    do: for({{Silent, _key}, {_kind, record}} <- branch.overlay, do: record.text) |> Enum.sort()

  defp seqs(id), do: Enum.map(deltas(id), &elem(&1, 0))

  # What a crash of the node leaves: the process gone without running terminate/2, its marks cleared as a restart
  # clears them (the ETS tables of the supervisor are the only thing the test cannot lose, and storage is one of them).
  defp crash(id) do
    pid = Ramal.Supervisor.whereis(id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    eventually(fn -> Ramal.Supervisor.too_large?(id) end)
    Ramal.Supervisor.clear_too_large(id)
    Ramal.Supervisor.clear_running(id)
    eventually(fn -> not loaded?(id) end)
  end

  defp create(branch, text),
    do: Ramal.run!(branch, fn -> Ash.create!(Silent, %{text: text}, authorize?: false) end)

  describe "a durable branch whose process is killed" do
    test "keeps every write of every action that ended" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      a = create(branch, "a")

      Ramal.run!(branch, fn ->
        Ash.update!(a, %{text: "a2"}, authorize?: false)
        Ash.create!(Silent, %{text: "b"}, authorize?: false)
      end)

      c = create(branch, "c")
      Ramal.run!(branch, fn -> Ash.destroy!(c, authorize?: false) end)
      before = state(branch.id)
      assert texts(before) == ["a2", "b"]

      crash(branch.id)
      recovered = state(branch.id)

      assert recovered.overlay == before.overlay
      assert recovered.base == before.base
      assert recovered.log == before.log
      assert recovered.wal == before.wal
      assert recovered.durable
      assert {:ok, changes} = Ramal.diff(branch)
      assert length(changes) == 2
    end

    test "can be merged after the crash, and the merge writes what the branch held" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      create(branch, "kept")

      crash(branch.id)

      assert {:ok, %{replayed: 1}} = Ramal.merge(branch, authorize?: false)
      assert "kept" in Enum.map(Ash.read!(Silent, authorize?: false), & &1.text)
    after
      # The table is shared with other tests, which leave rows of their own; remove only this one.
      for %{text: "kept"} = record <- Ash.read!(Silent, authorize?: false),
          do: Ash.destroy!(record, authorize?: false)
    end

    test "is the same branch that a branch which is not durable would have lost" do
      {:ok, branch} = Ramal.branch(Capture)
      create(branch, "lost")
      refute branch.durable
      assert deltas(branch.id) == []

      crash(branch.id)

      assert state(branch.id).overlay == %{}
    end

    test "starts a write log of its own after a recovery, compacting the one it applied" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      create(branch, "a")
      create(branch, "b")
      assert seqs(branch.id) == [1, 2]

      crash(branch.id)
      assert texts(state(branch.id)) == ["a", "b"]

      # The process stored a snapshot that covers what it applied, then goes on from there.
      eventually(fn -> deltas(branch.id) == [] end)
      assert {:ok, %{wal: 2}} = ETS.fetch(branch.id, [])
      create(branch, "c")
      assert seqs(branch.id) == [3]
    end
  end

  describe "an action that does not end well" do
    test "that fails leaves no delta" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)

      assert {:ok, {:error, _}} =
               Ramal.run(branch, fn ->
                 Ash.create(Flaky, %{text: "x"}, action: :create_then_fail)
               end)

      assert deltas(branch.id) == []
      crash(branch.id)
      assert state(branch.id).overlay == %{}
    end

    test "that raises leaves no delta" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)

      assert_raise Ash.Error.Unknown, fn ->
        Ramal.run(branch, fn -> Ash.create(Flaky, %{text: "x"}, action: :create_then_raise) end)
      end

      assert deltas(branch.id) == []
      crash(branch.id)
      assert state(branch.id).overlay == %{}
    end

    test "that makes no write has nothing to append" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      assert {:ok, :ok} = Ramal.run(branch, fn -> :ok end)
      assert deltas(branch.id) == []
    end
  end

  describe "an action returns" do
    test "after its writes are in the write log" do
      Process.register(self(), :ramal_test_append_watch)
      {:ok, branch} = Ramal.branch(Capture, durable: true)

      create(branch, "a")

      assert_received {:appended, 1}
      assert seqs(branch.id) == [1]
    end

    test "one delta for the outermost action, whatever its hooks wrote" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)

      Ramal.run!(branch, fn ->
        for i <- 1..3, do: Ash.create!(Silent, %{text: "t#{i}"}, authorize?: false)
      end)

      # Three actions of the process, one delta each; a delta holds the rows its action wrote and no other.
      assert [{1, one}, {2, two}, {3, three}] = deltas(branch.id)
      assert Enum.map([one, two, three], &map_size(&1.overlay)) == [1, 1, 1]
      assert Enum.map([one, two, three], &length(&1.log)) == [1, 1, 1]
    end
  end

  describe "two actions running in one branch" do
    # Gated holds an action between its write and its end, until the test lets it pass.
    setup do
      Process.register(self(), :ramal_test_gate)
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      {:ok, branch: branch}
    end

    defp start_gated(branch, text) do
      test = self()

      pid =
        spawn(fn ->
          send(
            test,
            {:ended, self(),
             Ramal.run(branch, fn -> Ash.create(Gated, %{text: text}, action: :gated_create) end)}
          )
        end)

      assert_receive {:at_gate, ^pid}, 1_000
      pid
    end

    defp gated_texts(branch),
      do:
        for({{Gated, _key}, {_kind, record}} <- state(branch.id).overlay, do: record.text)
        |> Enum.sort()

    test "store only the action that ended", %{branch: branch} do
      first = start_gated(branch, "first")
      # The gate lets an action through once no test is registered for it.
      Process.unregister(:ramal_test_gate)

      Ramal.run!(branch, fn ->
        Ash.create!(Gated, %{text: "second"}, action: :gated_create, authorize?: false)
      end)

      assert gated_texts(branch) == ["first", "second"]
      assert [{1, delta}] = deltas(branch.id)
      assert [%{text: "second"}] = for({_ref, {_kind, record}} <- delta.overlay, do: record)
      assert [_one_entry] = delta.log

      send(first, {:gate, :pass})
      assert_receive {:ended, ^first, {:ok, {:ok, _}}}

      assert [{1, _}, {2, second}] = deltas(branch.id)
      assert [%{text: "first"}] = for({_ref, {_kind, record}} <- second.overlay, do: record)
    end

    test "a crash while one is running keeps the one that ended and not the one that did not", %{
      branch: branch
    } do
      first = start_gated(branch, "first")
      Process.unregister(:ramal_test_gate)

      Ramal.run!(branch, fn ->
        Ash.create!(Gated, %{text: "second"}, action: :gated_create, authorize?: false)
      end)

      crash(branch.id)

      assert gated_texts(branch) == ["second"]
      Process.exit(first, :kill)
    end

    test "one that ends and one that fails leave the one that ended", %{branch: branch} do
      first = start_gated(branch, "first")
      Process.unregister(:ramal_test_gate)

      Ramal.run!(branch, fn ->
        Ash.create!(Gated, %{text: "second"}, action: :gated_create, authorize?: false)
      end)

      send(first, {:gate, :fail})
      assert_receive {:ended, ^first, {:ok, {:error, _}}}

      assert seqs(branch.id) == [1]
      crash(branch.id)
      assert gated_texts(branch) == ["second"]
    end

    test "are recovered in the order they ended in", %{branch: branch} do
      first = start_gated(branch, "first")
      Process.unregister(:ramal_test_gate)

      Ramal.run!(branch, fn ->
        Ash.create!(Gated, %{text: "second"}, action: :gated_create, authorize?: false)
      end)

      send(first, {:gate, :pass})
      assert_receive {:ended, ^first, {:ok, {:ok, _}}}

      crash(branch.id)

      assert [:gated_create, :gated_create] = Enum.map(state(branch.id).log, &elem(&1, 2))

      assert state(branch.id).log |> Enum.reverse() |> Enum.map(&elem(&1, 3).text) == [
               "second",
               "first"
             ]
    end
  end

  describe "the write log is compacted" do
    test "by a snapshot every hundred appends, which deletes the deltas it covers" do
      test = self()
      handler = "compact-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:ramal, :branch, :compact],
        fn _, m, meta, _ -> send(test, {:compact, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, branch} = Ramal.branch(Capture, durable: true)

      Ramal.run!(branch, fn ->
        for i <- 1..100, do: Ash.create!(Silent, %{text: "t#{i}"}, authorize?: false)
      end)

      assert_receive {:compact, %{duration: duration}, %{wal: 100, branch_id: id}}, 2_000
      assert duration >= 0
      assert id == branch.id
      assert deltas(branch.id) == []
      assert {:ok, %{wal: 100, overlay: overlay}} = ETS.fetch(branch.id, [])
      assert map_size(overlay) == 100

      for i <- 101..103, do: create(branch, "t#{i}")
      assert seqs(branch.id) == [101, 102, 103]

      before = state(branch.id)
      crash(branch.id)
      recovered = state(branch.id)

      assert map_size(recovered.overlay) == 103
      assert recovered.overlay == before.overlay
      assert recovered.log == before.log
      assert recovered.base == before.base
    end

    test "without the writes of an action that is still running" do
      Process.register(self(), :ramal_test_gate)
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      test = self()

      pid =
        spawn(fn ->
          send(
            test,
            {:ended, self(),
             Ramal.run(branch, fn -> Ash.create(Gated, %{text: "held"}, action: :gated_create) end)}
          )
        end)

      assert_receive {:at_gate, ^pid}, 1_000
      Process.unregister(:ramal_test_gate)

      # A hundred actions while that one runs: the snapshot taken after the hundredth leaves out what it holds.
      Ramal.run!(branch, fn ->
        for i <- 1..100, do: Ash.create!(Silent, %{text: "t#{i}"}, authorize?: false)
      end)

      eventually(fn -> deltas(branch.id) == [] end)

      assert {:ok, stored} = ETS.fetch(branch.id, [])
      assert stored.wal == 100
      assert map_size(stored.overlay) == 100
      refute Enum.any?(stored.overlay, fn {{resource, _key}, _entry} -> resource == Gated end)

      send(pid, {:gate, :pass})
      assert_receive {:ended, ^pid, {:ok, {:ok, _}}}
      assert [{101, delta}] = deltas(branch.id)
      assert [{Gated, _}] = Map.keys(delta.overlay)
    end

    test "when the branch unloads, which stores it whole" do
      stop_supervised!(Ramal.Supervisor)
      start_supervised!({Ramal.Supervisor, storage: DurableStorage, idle_timeout: 50})

      {:ok, branch} = Ramal.branch(Capture, durable: true)
      create(branch, "a")
      create(branch, "b")

      eventually(fn -> not loaded?(branch.id) end)

      assert deltas(branch.id) == []
      assert {:ok, %{wal: 2, overlay: overlay}} = ETS.fetch(branch.id, [])
      assert map_size(overlay) == 2
      assert texts(state(branch.id)) == ["a", "b"]
      create(branch, "c")
      assert seqs(branch.id) == [3]
    end

    test "when the branch is discarded, which deletes its log" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      create(branch, "a")
      assert seqs(branch.id) == [1]

      assert :ok = Ramal.discard(branch)

      assert deltas(branch.id) == []
      assert {:ok, %{status: :discarded, overlay: overlay}} = Ramal.get(branch.id)
      assert overlay == %{}
    end
  end

  describe "a fork of a durable branch" do
    test "is durable, starts a write log of its own, and survives a crash with what it copied" do
      {:ok, parent} = Ramal.branch(Capture, durable: true)
      create(parent, "from the parent")
      create(parent, "also from the parent")

      {:ok, fork} = Ramal.fork(parent)

      assert fork.durable
      assert fork.wal == 0
      assert deltas(fork.id) == []
      assert {:ok, %{wal: 0, overlay: copied}} = ETS.fetch(fork.id, [])
      assert map_size(copied) == 2

      create(fork, "from the fork")
      assert seqs(fork.id) == [1]
      assert seqs(parent.id) == [1, 2]

      crash(fork.id)

      assert texts(state(fork.id)) == ["also from the parent", "from the fork", "from the parent"]
      assert texts(state(parent.id)) == ["also from the parent", "from the parent"]
    end

    test "can be made durable from a branch that is not, or the other way round" do
      {:ok, parent} = Ramal.branch(Capture)
      {:ok, durable_fork} = Ramal.fork(parent, durable: true)
      assert durable_fork.durable

      create(durable_fork, "x")
      assert seqs(durable_fork.id) == [1]

      {:ok, durable_parent} = Ramal.branch(Capture, durable: true)
      {:ok, plain_fork} = Ramal.fork(durable_parent, durable: false)
      refute plain_fork.durable
    end
  end

  describe "a storage that fails" do
    test "to append fails the action, which leaves nothing behind" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      Process.register(self(), :ramal_test_append_down)

      assert {:ok, {:error, error}} =
               Ramal.run(branch, fn -> Ash.create(Silent, %{text: "x"}, authorize?: false) end)

      assert %Ramal.Error{reason: :storage} = Ramal.Error.find(error)
      assert state(branch.id).overlay == %{}
      assert state(branch.id).log == []
      assert deltas(branch.id) == []

      # The storage is back: the next action is stored, under a number the failed one did not reuse.
      Process.unregister(:ramal_test_append_down)
      create(branch, "y")
      assert seqs(branch.id) == [2]
      crash(branch.id)
      assert texts(state(branch.id)) == ["y"]
    end

    test "to answer after it stored the delta does not bring the action back after a crash" do
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      Process.register(self(), :ramal_test_append_lost)

      assert {:ok, {:error, _}} =
               Ramal.run(branch, fn ->
                 Ash.create(Silent, %{text: "phantom"}, authorize?: false)
               end)

      Process.unregister(:ramal_test_append_lost)

      # The delta was stored, though the action failed; the snapshot the process stores at once covers its number.
      eventually(fn -> deltas(branch.id) == [] end)
      create(branch, "real")

      crash(branch.id)

      assert texts(state(branch.id)) == ["real"]
    end

    test "emits persist_failed with the reason :append" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      Process.register(self(), :ramal_test_append_down)

      Ramal.run(branch, fn -> Ash.create(Silent, %{text: "x"}, authorize?: false) end)

      assert_receive {:telemetry, [:ramal, :branch, :persist_failed],
                      %{reason: :append, error: %Ramal.Error{}}}
    end
  end

  describe "a branch process that stops with an action running" do
    test "stores a durable branch without the write of that action" do
      Process.register(self(), :ramal_test_gate)
      {:ok, branch} = Ramal.branch(Capture, durable: true)
      create(branch, "ended")
      test = self()

      pid =
        spawn(fn ->
          send(
            test,
            {:ended, self(),
             Ramal.run(branch, fn -> Ash.create(Gated, %{text: "held"}, action: :gated_create) end)}
          )
        end)

      assert_receive {:at_gate, ^pid}, 1_000

      :ok = GenServer.stop(Ramal.Supervisor.whereis(branch.id))

      assert {:ok, stored} = ETS.fetch(branch.id, [])
      assert texts(stored) == ["ended"]
      assert Enum.all?(stored.log, &(elem(&1, 1) == Silent))
      Process.exit(pid, :kill)
    end
  end

  describe "the telemetry of the write log" do
    test "an append is announced with its number, its rows and its duration" do
      test = self()
      handler = "append-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:ramal, :branch, :append],
        fn _, m, meta, _ -> send(test, {:append, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, branch} = Ramal.branch(Capture, durable: true)
      create(branch, "a")

      assert_receive {:append, %{duration: duration, system_time: _},
                      %{branch_id: id, domain: Capture, seq: 1, rows: 1}}

      assert id == branch.id
      assert duration >= 0
    end

    test "is part of the branch events" do
      assert [:ramal, :branch, :append] in Ramal.Telemetry.branch_events()
      assert [:ramal, :branch, :compact] in Ramal.Telemetry.branch_events()
    end

    test "a branch that is not durable emits neither" do
      test = self()
      handler = "none-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler,
        [[:ramal, :branch, :append], [:ramal, :branch, :compact]],
        fn e, _, _, _ -> send(test, {:wal, e}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, branch} = Ramal.branch(Capture)

      Ramal.run!(branch, fn ->
        for i <- 1..120, do: Ash.create!(Silent, %{text: "t#{i}"}, authorize?: false)
      end)

      refute_receive {:wal, _}, 100
      assert deltas(branch.id) == []
    end
  end

  describe "the supervisor's durable option" do
    @tag supervisor: [storage: DurableStorage, durable: true]
    test "makes every branch durable unless the call says otherwise" do
      {:ok, default} = Ramal.branch(Capture)
      {:ok, plain} = Ramal.branch(Capture, durable: false)

      assert default.durable
      refute plain.durable
      create(default, "a")
      create(plain, "b")
      assert seqs(default.id) == [1]
      assert seqs(plain.id) == []
    end
  end

  describe "a storage without the write log" do
    @tag supervisor: [storage: Ramal.Test.PlainStorage]
    test "refuses a durable branch, and keeps working for the others" do
      assert {:error,
              %Ramal.Error{
                reason: :durability_unsupported,
                message: message,
                details: %{storage: Ramal.Test.PlainStorage}
              }} =
               Ramal.branch(Capture, durable: true)

      assert message =~ "append/4"
      assert {:ok, branch} = Ramal.branch(Capture)
      create(branch, "a")
      assert {:ok, [_change]} = Ramal.diff(branch)
    end

    @tag supervisor: [storage: Ramal.Test.PlainStorage]
    test "refuses a durable fork" do
      {:ok, parent} = Ramal.branch(Capture)

      assert {:error, %Ramal.Error{reason: :durability_unsupported}} =
               Ramal.fork(parent, durable: true)
    end

    @tag supervisor: false
    test "makes a supervisor with durable: true refuse to start" do
      assert {:error, reason} =
               start_supervised(
                 {Ramal.Supervisor, storage: Ramal.Test.PlainStorage, durable: true}
               )

      assert inspect(reason) =~ "write log"
    end

    test "is a storage that Ramal.Storage.durable?/1 says so about" do
      assert Ramal.Storage.durable?(Ramal.Storage.ETS)
      assert Ramal.Storage.durable?(Ramal.Test.DurableStorage)
      refute Ramal.Storage.durable?(Ramal.Test.PlainStorage)
    end
  end
end
