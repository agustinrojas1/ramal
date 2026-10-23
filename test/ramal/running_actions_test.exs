defmodule Ramal.RunningActionsTest do
  # What other processes see of an action that has written to a branch and has not ended yet. The cases come from the
  # TLA+ model in verification/tla, which found each of them; every test here failed before the fix.
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.BranchCase, async: false

  alias Ramal.Test.Capture
  alias Ramal.Test.Capture.Gated

  setup do
    Process.register(self(), :ramal_test_gate)
    {:ok, branch} = Ramal.branch(Capture)
    {:ok, branch: branch}
  end

  # Starts `fun` inside the branch in a process of its own and waits until its action stands at the gate.
  defp start_action(branch, fun) do
    test = self()
    pid = spawn(fn -> send(test, {:ended, self(), Ramal.run(branch, fun)}) end)
    assert_receive {:at_gate, ^pid}, 1_000
    pid
  end

  defp open_gate(pid, outcome) do
    if Process.whereis(:ramal_test_gate), do: Process.unregister(:ramal_test_gate)
    send(pid, {:gate, outcome})
  end

  defp in_background(fun) do
    test = self()
    ref = make_ref()
    spawn(fn -> send(test, {ref, fun.()}) end)
    ref
  end

  defp state(branch), do: elem(Ramal.get(branch.id), 1)
  defp db_texts, do: Gated |> Ash.read!(authorize?: false) |> Enum.map(& &1.text)

  setup do
    on_exit(fn ->
      for record <- Ash.read!(Gated, authorize?: false),
          do: Ash.destroy!(record, authorize?: false)
    end)
  end

  describe "an action whose process dies before it ends" do
    test "is taken back like an action that failed", %{branch: branch} do
      pid = start_action(branch, fn -> Ash.create(Gated, %{text: "x"}, action: :gated_create) end)
      assert [_write] = state(branch).log

      Process.exit(pid, :kill)

      eventually(fn -> state(branch).log == [] end)
      assert state(branch).overlay == %{}
      assert {:ok, []} = Ramal.diff(branch)
    end
  end

  describe "a merge while an action is running" do
    test "waits for the action and does not replay it when it fails", %{branch: branch} do
      pid = start_action(branch, fn -> Ash.create(Gated, %{text: "x"}, action: :gated_create) end)
      merge = in_background(fn -> Ramal.merge(branch, authorize?: false) end)
      refute_receive {^merge, _}, 100

      open_gate(pid, :fail)

      assert_receive {:ended, ^pid, {:ok, {:error, _}}}
      assert_receive {^merge, {:ok, %Ramal.Merge.Result{replayed: 0}}}, 2_000
      assert db_texts() == []
    end

    test "waits for the action and replays it when it succeeds", %{branch: branch} do
      pid = start_action(branch, fn -> Ash.create(Gated, %{text: "x"}, action: :gated_create) end)
      merge = in_background(fn -> Ramal.merge(branch, authorize?: false) end)
      refute_receive {^merge, _}, 100

      open_gate(pid, :pass)

      assert_receive {:ended, ^pid, {:ok, {:ok, _}}}
      assert_receive {^merge, {:ok, %Ramal.Merge.Result{replayed: 1}}}, 2_000
      assert db_texts() == ["x"]
    end

    test "refuses a new action meanwhile", %{branch: branch} do
      pid = start_action(branch, fn -> Ash.create(Gated, %{text: "x"}, action: :gated_create) end)
      merge = in_background(fn -> Ramal.merge(branch, authorize?: false) end)
      refute_receive {^merge, _}, 100

      assert {:ok, {:error, error}} = Ramal.run(branch, fn -> Ash.create(Gated, %{text: "y"}) end)
      assert %Ramal.Error{reason: :not_open} = Ramal.Error.find(error)

      open_gate(pid, :pass)
      assert_receive {^merge, {:ok, %Ramal.Merge.Result{replayed: 1}}}, 2_000
    end
  end

  describe "a proposal while an action is running" do
    test "waits for the action, so a failed write is not proposed", %{branch: branch} do
      pid = start_action(branch, fn -> Ash.create(Gated, %{text: "x"}, action: :gated_create) end)
      propose = in_background(fn -> Ramal.propose(branch) end)
      refute_receive {^propose, _}, 100

      open_gate(pid, :fail)

      assert_receive {^propose, {:ok, %{status: :proposed, log: []}}}, 2_000
      assert {:ok, []} = Ramal.diff(branch)
    end
  end

  describe "a fork while an action is running" do
    test "does not copy the running action's write", %{branch: branch} do
      pid = start_action(branch, fn -> Ash.create(Gated, %{text: "x"}, action: :gated_create) end)
      {:ok, fork} = Ramal.fork(branch)

      open_gate(pid, :fail)
      assert_receive {:ended, ^pid, {:ok, {:error, _}}}

      assert state(fork).log == []
      assert state(fork).overlay == %{}
      assert state(branch).log == []
    end
  end

  describe "two actions on the same row" do
    test "the second is refused while the first is running", %{branch: branch} do
      row = Ash.create!(Gated, %{text: "base"}, authorize?: false)

      pid =
        start_action(branch, fn ->
          Ash.update(row, %{text: "first"}, action: :gated_update, authorize?: false)
        end)

      assert {:ok, {:error, error}} =
               Ramal.run(branch, fn -> Ash.update(row, %{text: "second"}, authorize?: false) end)

      assert %Ramal.Error{reason: :row_busy} = Ramal.Error.find(error)

      open_gate(pid, :fail)
      assert_receive {:ended, ^pid, {:ok, {:error, _}}}

      # What a read in the branch sees and what a merge would replay agree: nothing.
      assert state(branch).overlay == %{}
      assert state(branch).log == []
    end
  end

  describe "a branch process killed by max_heap_size" do
    test "is not loaded again from storage before its watcher marks it", %{branch: branch} do
      id = branch.id
      assert {:ok, :ok} = Ramal.run(branch, fn -> Ash.create(Gated, %{text: "x"}) && :ok end)
      pid = Ramal.Supervisor.whereis(id)

      # The watcher is the process that monitors the branch process; hold it so the kill goes unmarked for now.
      {:monitored_by, [watcher | _]} = Process.info(pid, :monitored_by)
      :erlang.suspend_process(watcher)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      eventually(fn -> Registry.lookup(Ramal.Supervisor.registry(), id) == [] end)

      # Storage holds the branch as it was created, without the write the run made.
      assert {:error, %Ramal.Error{reason: :branch_too_large}} = Ramal.get(id)
      :erlang.resume_process(watcher)
    end
  end
end
