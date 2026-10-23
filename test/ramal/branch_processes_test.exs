defmodule Ramal.BranchProcessesTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.BranchCase, async: false

  alias Ramal.Storage.ETS
  alias Ramal.Supervisor, as: RamalSupervisor
  alias Ramal.Test.{Farm, Other, Plain}

  doctest Ramal.Supervisor
  doctest Ramal.Telemetry

  defmodule FlakyStorage do
    @moduledoc false
    # ETS storage whose writes fail while a test has registered itself as :ramal_test_storage_down.
    @behaviour Ramal.Storage

    defdelegate fetch(id, config), to: ETS
    defdelegate delete(id, config), to: ETS
    defdelegate list(domain, filters, config), to: ETS
    defdelegate count(domain, statuses, config), to: ETS

    def put(branch, config) do
      if Process.whereis(:ramal_test_storage_down) do
        {:error, Ramal.Error.new(:storage, "storage is down")}
      else
        ETS.put(branch, config)
      end
    end
  end

  defp touch(id, ref, record) do
    {:ok, branch} =
      Server.update(id, &%{&1 | overlay: Overlay.put_created(&1.overlay, ref, record)})

    branch
  end

  describe "branch/2" do
    test "refuses a domain with no branchable resource and creates nothing" do
      for domain <- [Plain, NotADomain] do
        assert {:error, %Error{reason: :no_branchable_resources, details: %{domain: ^domain}}} =
                 Ramal.branch(domain)
      end

      assert {:ok, []} = Ramal.list(Plain)
    end

    test "refuses a domain with a resource that has write actions and no extension, naming it" do
      assert {:error, %Error{reason: :unbranchable_resources, details: details}} =
               Ramal.branch(Ramal.Test.Uncovered)

      assert details == %{domain: Ramal.Test.Uncovered, resources: [Ramal.Test.Uncovered.Note]}
      assert {:ok, []} = Ramal.list(Ramal.Test.Uncovered)
    end

    test "accepts a domain whose other resources opt out explicitly or have no write action" do
      assert {:ok, _branch} = Ramal.branch(Ramal.Test.OptedOut)
      assert Ramal.Resource.uncovered(Ramal.Test.OptedOut) == []
    end

    test "creates an open branch, starts its process and makes it readable by id" do
      assert {:ok, branch} =
               Ramal.branch(Farm, name: "what if", metadata: %{ticket: 1})

      assert %{status: :open, name: "what if", domain: Farm, metadata: %{ticket: 1}} =
               branch

      assert loaded?(branch.id)
      assert Ramal.get(branch.id) == {:ok, branch}
    end

    test "persists the branch right away, so a crash before the first unload cannot lose its existence" do
      {:ok, branch} = Ramal.branch(Farm)

      assert ETS.fetch(branch.id, []) == {:ok, branch}
    end

    test "emits create and load events with the branch id and domain" do
      capture_branch_events()

      {:ok, branch} = Ramal.branch(Farm)

      assert_receive {:telemetry, [:ramal, :branch, :load], %{branch_id: id, domain: Farm}}

      assert_receive {:telemetry, [:ramal, :branch, :create], %{branch_id: ^id, domain: Farm}}

      assert id == branch.id
    end

    @tag supervisor: false
    test "returns :not_started with an actionable message when Ramal.Supervisor is not running" do
      assert {:error, %Error{reason: :not_started} = error} = Ramal.branch(Farm)

      assert error.message =~ "Ramal.Supervisor"
      assert {:error, %Error{reason: :not_started}} = Ramal.get("any")
      assert {:error, %Error{reason: :not_started}} = Ramal.list(Farm)
    end
  end

  describe "isolation" do
    test "an entry put into one branch is invisible to another branch of the same domain" do
      {:ok, a} = Ramal.branch(Farm, name: "a")
      {:ok, b} = Ramal.branch(Farm, name: "b")

      touch(a.id, {Herd, 1}, %{id: 1})

      assert {:ok, %{overlay: %{{Herd, 1} => {:created, %{id: 1}}}}} = Ramal.get(a.id)
      assert {:ok, %{overlay: overlay_b}} = Ramal.get(b.id)
      assert overlay_b == %{}
    end

    test "each branch is its own process" do
      {:ok, a} = Ramal.branch(Farm)
      {:ok, b} = Ramal.branch(Farm)

      assert RamalSupervisor.whereis(a.id) != RamalSupervisor.whereis(b.id)
    end

    test "run/2 makes the branch current only for the calling process" do
      {:ok, a} = Ramal.branch(Farm)
      {:ok, b} = Ramal.branch(Farm)

      Ramal.run!(a, fn ->
        assert Ramal.current().id == a.id

        # A task started inside run/2 is in the same branch (ADR 0026), and it can still run another one without that
        # counting as nested.
        assert Task.async(fn -> Ramal.current().id end) |> Task.await() == a.id

        assert Task.async(fn -> Ramal.run!(b, fn -> Ramal.current().id end) end) |> Task.await() ==
                 b.id

        assert Ramal.current().id == a.id
      end)
    end
  end

  describe "run/2" do
    test "returns the function's result in an ok tuple and accepts a branch or its id" do
      {:ok, branch} = Ramal.branch(Farm)

      assert Ramal.run(branch, fn -> :by_struct end) == {:ok, :by_struct}
      assert Ramal.run(branch.id, fn -> :by_id end) == {:ok, :by_id}
      assert Ramal.run!(branch, fn -> 42 end) == 42
    end

    test "current/0 is nil outside run/2 and the running branch inside it" do
      {:ok, branch} = Ramal.branch(Farm)

      assert Ramal.current() == nil
      assert Ramal.run!(branch, fn -> Ramal.current() end) == branch
      assert Ramal.current() == nil
    end

    test "current/0 reflects writes made after run/2 started" do
      {:ok, branch} = Ramal.branch(Farm)

      overlay =
        Ramal.run!(branch, fn ->
          touch(branch.id, {Herd, 1}, %{id: 1})
          Ramal.current().overlay
        end)

      assert overlay == %{{Herd, 1} => {:created, %{id: 1}}}
    end

    test "current/0 is nil again after the function raises" do
      {:ok, branch} = Ramal.branch(Farm)

      assert_raise RuntimeError, "boom", fn -> Ramal.run(branch, fn -> raise "boom" end) end

      assert Ramal.current() == nil
      assert Ramal.run(branch, fn -> :still_works end) == {:ok, :still_works}
    end

    test "current/0 is nil again after the function throws or exits" do
      {:ok, branch} = Ramal.branch(Farm)

      assert catch_throw(Ramal.run(branch, fn -> throw(:ball) end)) == :ball
      assert Ramal.current() == nil
      assert catch_exit(Ramal.run(branch, fn -> exit(:bye) end)) == :bye
      assert Ramal.current() == nil
    end

    test "a nested run/2 returns :nested_branch, does not run its function, and leaves the outer run intact" do
      {:ok, outer} = Ramal.branch(Farm)
      {:ok, inner} = Ramal.branch(Farm)
      test = self()

      {:ok, nested} =
        Ramal.run(outer, fn ->
          result = Ramal.run(inner, fn -> send(test, :inner_ran) end)
          {result, Ramal.current().id}
        end)

      assert {{:error, %Error{reason: :nested_branch, details: details}}, current_id} = nested
      assert details == %{current: outer.id, requested: inner.id}
      assert current_id == outer.id
      refute_received :inner_ran
    end

    test "running the same branch inside itself is nested too" do
      {:ok, branch} = Ramal.branch(Farm)

      {:ok, result} = Ramal.run(branch, fn -> Ramal.run(branch, fn -> :nope end) end)

      assert {:error, %Error{reason: :nested_branch}} = result
    end

    test "run!/2 raises the Ramal.Error that run/2 would return" do
      {:ok, branch} = Ramal.branch(Farm)

      error =
        assert_raise Error, fn ->
          Ramal.run!(branch, fn -> Ramal.run!(branch, fn -> :nope end) end)
        end

      assert error.reason == :nested_branch
    end

    test "an unknown id is :not_found and the function does not run" do
      assert {:error, %Error{reason: :not_found}} =
               Ramal.run("00000000-0000-0000-0000-000000000000", fn -> flunk("ran") end)
    end
  end

  describe "a storage that refuses the write" do
    @describetag supervisor: [idle_timeout: 60, storage: FlakyStorage]

    test "an idle branch stays loaded with its overlay until the write succeeds" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Farm, name: "sleepy")
      id = branch.id
      expected = touch(id, {Herd, 7}, %{id: 7, name: "R7"})

      Process.register(self(), :ramal_test_storage_down)

      assert_receive {:telemetry, [:ramal, :branch, :persist_failed],
                      %{branch_id: ^id, reason: :idle}},
                     1_000

      assert loaded?(id)
      refute_received {:telemetry, [:ramal, :branch, :unload], _}
      assert Ramal.get(id) == {:ok, expected}

      Process.unregister(:ramal_test_storage_down)
      eventually(fn -> not loaded?(id) end)
      assert_received {:telemetry, [:ramal, :branch, :unload], %{branch_id: ^id, reason: :idle}}
      assert {:ok, ^expected} = ETS.fetch(id, [])
    end

    test "a shutdown whose write fails reports it instead of announcing an unload" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Farm)
      id = branch.id
      pid = RamalSupervisor.whereis(id)

      Process.register(self(), :ramal_test_storage_down)
      :ok = DynamicSupervisor.terminate_child(RamalSupervisor.dynamic_supervisor(), pid)

      assert_received {:telemetry, [:ramal, :branch, :persist_failed],
                       %{branch_id: ^id, reason: :shutdown}}

      refute_received {:telemetry, [:ramal, :branch, :unload], _}
    end
  end

  describe "idle unload and rehydration" do
    @describetag supervisor: [idle_timeout: 60]

    test "an idle branch persists its overlay, stops, and comes back identical on the next use" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Farm, name: "sleepy", metadata: %{a: 1})
      expected = touch(branch.id, {Herd, 7}, %{id: 7, name: "R7"})

      eventually(fn -> not loaded?(branch.id) end)
      assert_received {:telemetry, [:ramal, :branch, :unload], %{branch_id: id, reason: :idle}}
      assert id == branch.id
      assert {:ok, ^expected} = ETS.fetch(branch.id, [])

      assert Ramal.get(branch.id) == {:ok, expected}
      assert loaded?(branch.id)
      assert_received {:telemetry, [:ramal, :branch, :load], %{branch_id: ^id}}
    end

    test "a branch comes back from storage with its rows sharing the terms they shared before" do
      {:ok, branch} = Ramal.branch(Farm)
      owner = String.duplicate("o", 40)
      snapshot = %{id: 7, owner: owner, n: 1}
      row = %{fingerprint: 1, snapshot: snapshot}
      entry = {:update, Herd, :update, %{n: 2}, nil, [key: 7], DateTime.utc_now()}

      {:ok, _} =
        Server.update(branch.id, fn branch ->
          {branch, _} =
            Ramal.Branch.put_write(branch, :updated, {Herd, 7}, %{snapshot | n: 2}, row, entry)

          branch
        end)

      eventually(fn -> not loaded?(branch.id) end)

      # The ETS copy kept no sharing, so what the check sees was shared by the process that loaded the branch.
      {:ok, shared?, _} =
        Server.write(branch.id, fn branch ->
          {:updated, record} = branch.overlay[{Herd, 7}]
          {:erts_debug.same(record.owner, branch.base[{Herd, 7}].snapshot.owner), branch}
        end)

      assert shared?
    end

    test "run/2 on an unloaded branch rehydrates it and sees its overlay" do
      {:ok, branch} = Ramal.branch(Farm)
      touch(branch.id, {Herd, 7}, %{id: 7})
      eventually(fn -> not loaded?(branch.id) end)

      assert {:ok, overlay} = Ramal.run(branch.id, fn -> Ramal.current().overlay end)
      assert overlay == %{{Herd, 7} => {:created, %{id: 7}}}
    end

    test "many callers waking the same unloaded branch at once end up with one process and the same state" do
      {:ok, branch} = Ramal.branch(Farm)
      expected = touch(branch.id, {Herd, 1}, %{id: 1})
      eventually(fn -> not loaded?(branch.id) end)

      results =
        1..40
        |> Task.async_stream(fn _ -> Ramal.get(branch.id) end, max_concurrency: 40)
        |> Enum.map(&elem(&1, 1))

      assert Enum.all?(results, &(&1 == {:ok, expected}))
      assert Registry.count(RamalSupervisor.registry()) == 1
    end

    test "a call that races with the unload is retried instead of failing" do
      {:ok, branch} = Ramal.branch(Farm)

      # Calling at roughly the idle deadline over and over hits the window between :timeout and the stop.
      results =
        for _ <- 1..60 do
          Process.sleep(58)
          Ramal.get(branch.id)
        end

      assert Enum.reject(results, &match?({:ok, %{id: _}}, &1)) == []
    end
  end

  describe "discard/1" do
    test "stops the process, drops the overlay and keeps a discarded record" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Farm)
      touch(branch.id, {Herd, 1}, %{id: 1})

      assert Ramal.discard(branch) == :ok

      refute loaded?(branch.id)
      assert_received {:telemetry, [:ramal, :branch, :discard], %{branch_id: id}}
      assert id == branch.id
      refute_received {:telemetry, [:ramal, :branch, :unload], _}

      assert {:ok, %{status: :discarded, overlay: %{}, log: [], name: nil}} =
               ETS.fetch(branch.id, [])
    end

    test "a discarded branch cannot be run or updated, and discarding again is a no-op" do
      {:ok, branch} = Ramal.branch(Farm)
      :ok = Ramal.discard(branch)

      assert {:error, %Error{reason: :not_open, details: %{status: :discarded}}} =
               Ramal.run(branch, fn -> flunk("ran") end)

      assert {:error, %Error{reason: :not_open}} = Server.update(branch.id, & &1)
      assert Ramal.discard(branch.id) == :ok
      assert {:ok, %{status: :discarded}} = Ramal.get(branch.id)
    end

    test "status/1 answers with the status alone, for callers that must not copy the branch" do
      {:ok, branch} = Ramal.branch(Farm)
      touch(branch.id, {Farm.Herd, "R1"}, %{id: "R1"})
      assert Server.status(branch.id) == {:ok, :open}

      {:ok, _} = Server.update(branch.id, &%{&1 | status: :proposed})
      assert Server.status(branch.id) == {:ok, :proposed}

      assert {:error, %Error{reason: :not_found}} = Server.status(Ash.UUID.generate())
    end

    test "list/2 filters by status and reads from storage" do
      {:ok, open} = Ramal.branch(Farm, name: "open")
      {:ok, gone} = Ramal.branch(Farm, name: "gone")
      {:ok, _other_domain} = Ramal.branch(Other)
      :ok = Ramal.discard(gone)

      assert {:ok, all} = Ramal.list(Farm)
      assert Enum.map(all, & &1.id) |> Enum.sort() == Enum.sort([open.id, gone.id])
      assert {:ok, [%{id: id}]} = Ramal.list(Farm, status: :open)
      assert id == open.id
      assert {:ok, [discarded]} = Ramal.list(Farm, status: :discarded)
      assert discarded.id == gone.id
    end

    test "a merged branch cannot be discarded" do
      {:ok, branch} = Ramal.branch(Farm)
      # Merge (a later issue) will mark the record this way; the process holds the same status.
      {:ok, merged} = Server.update(branch.id, &%{&1 | status: :merged})
      assert merged.status == :merged

      assert {:error, %Error{reason: :not_open, details: %{status: :merged}}} =
               Ramal.discard(branch)
    end
  end

  describe "max_heap_size" do
    @describetag supervisor: [max_heap_size: 40_000]

    test "a branch that outgrows the limit is killed, reported, and refused until discarded" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Farm)
      id = branch.id

      assert {:error, %Error{reason: :branch_too_large}} =
               Server.update(id, fn b ->
                 %{b | overlay: Map.new(1..100_000, &{{Herd, &1}, :deleted})}
               end)

      eventually(fn -> not loaded?(id) end)
      assert_receive {:telemetry, [:ramal, :branch, :too_large], %{branch_id: ^id}}

      assert {:error, %Error{reason: :branch_too_large, message: message}} = Ramal.get(id)
      assert message =~ "max_heap_size"
      assert {:error, %Error{reason: :branch_too_large}} = Ramal.run(id, fn -> flunk("ran") end)

      assert Ramal.discard(id) == :ok
      assert {:ok, %{status: :discarded}} = Ramal.get(id)
    end

    test "the last persisted state remains after the kill" do
      {:ok, branch} = Ramal.branch(Farm, name: "kept")

      {:error, _} =
        Server.update(branch.id, fn b ->
          %{b | overlay: Map.new(1..100_000, &{{Herd, &1}, :deleted})}
        end)

      assert {:ok, %{name: "kept", overlay: %{}}} = ETS.fetch(branch.id, [])
    end
  end

  describe "supervisor shutdown" do
    test "persists every open branch before the processes go away" do
      capture_branch_events()
      {:ok, branch} = Ramal.branch(Farm)
      id = branch.id
      touch(id, {Herd, 1}, %{id: 1})
      pid = RamalSupervisor.whereis(id)
      ref = Process.monitor(pid)

      # Stopping through the dynamic supervisor is what an application shutdown does to each child.
      :ok = DynamicSupervisor.terminate_child(RamalSupervisor.dynamic_supervisor(), pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert_received {:telemetry, [:ramal, :branch, :unload],
                       %{branch_id: ^id, reason: :shutdown}}

      assert {:ok, %{overlay: %{{Herd, 1} => {:created, %{id: 1}}}}} =
               ETS.fetch(id, [])
    end
  end
end
