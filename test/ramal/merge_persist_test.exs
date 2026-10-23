defmodule Ramal.MergePersistStorage do
  @moduledoc false
  # ETS storage that refuses to store a merged branch while a test has registered itself as :ramal_test_merged_down.
  @behaviour Ramal.Storage

  alias Ramal.Storage.ETS

  defdelegate fetch(id, config), to: ETS
  defdelegate delete(id, config), to: ETS
  defdelegate list(domain, filters, config), to: ETS
  defdelegate count(domain, statuses, config), to: ETS

  def put(%{status: :merged} = branch, config) do
    if Process.whereis(:ramal_test_merged_down) do
      {:error, Ramal.Error.new(:storage, "boom")}
    else
      ETS.put(branch, config)
    end
  end

  def put(branch, config), do: ETS.put(branch, config)
end

defmodule Ramal.MergePersistTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Error
  alias Ramal.Merge.Result
  alias Ramal.Storage.ETS

  setup do
    start_supervised!({Ramal.Supervisor, storage: Ramal.MergePersistStorage, idle_timeout: 100})

    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)

    Ramal.run!(branch, fn ->
      Ash.create!(Herd, %{name: "M1", head: 1}, authorize?: false)
      Ash.update!(seeds.herds.r7, %{head: 77}, authorize?: false)
    end)

    Process.register(self(), :ramal_test_merged_down)
    {:ok, Map.put(seeds, :branch, branch)}
  end

  defp heads, do: Herd |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.head})

  describe "a storage that refuses the :merged write after the replay committed" do
    test "merge/2 still returns the result, with the failure in it", %{branch: branch} do
      assert {:ok, %Result{persist_failed: %Error{reason: :storage}, branch: %{status: :merged}}} =
               Ramal.merge(branch, authorize?: false)

      assert %{"M1" => 1, "R7" => 77} = heads()
    end

    test "the branch is merged in its process and refuses a second merge", %{branch: branch} do
      {:ok, _} = Ramal.merge(branch, authorize?: false)

      assert {:ok, %{status: :merged}} = Ramal.get(branch.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.merge(branch, authorize?: false)
      assert {:error, %Error{reason: :not_open}} = Ramal.run(branch, fn -> :ok end)
    end

    test "emits persist_failed, then stores the merged branch once the storage works", %{
      branch: branch
    } do
      id = branch.id
      handler = "merge-persist-#{inspect(self())}"
      test = self()

      :telemetry.attach(
        handler,
        [:ramal, :branch, :persist_failed],
        fn _event, _measurements, metadata, _config ->
          send(test, {:persist_failed, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} = Ramal.merge(branch, authorize?: false)
      assert_receive {:persist_failed, %{branch_id: ^id, reason: :merged}}

      Process.unregister(:ramal_test_merged_down)
      eventually(fn -> match?({:ok, %{status: :merged}}, ETS.fetch(id, [])) end)
    end

    test "approve/2 returns the result too and the proposal is not approved twice", %{
      branch: branch
    } do
      {:ok, _} = Ramal.propose(branch, reason: "go")

      assert {:ok, %Result{persist_failed: %Error{reason: :storage}}} =
               Ramal.approve(branch, authorize?: false)

      assert %{"M1" => 1, "R7" => 77} = heads()
      assert {:error, %Error{reason: :not_open}} = Ramal.approve(branch, authorize?: false)
    end
  end

  describe "a branch process that does not answer in time" do
    @tag timeout: 30_000
    test "a captured write that timed out is taken back, not applied late", %{branch: branch} do
      Process.unregister(:ramal_test_merged_down)

      # Keeps the process busy for longer than a call waits, so the write below times out while queued.
      pid = Ramal.Supervisor.whereis(branch.id)
      test = self()

      {:ok, {:error, error}} =
        Ramal.run(branch, fn ->
          # Keeps the process busy for longer than a call waits, so the write below times out while it is queued.
          spawn_link(fn ->
            send(
              test,
              {:busy,
               GenServer.call(
                 pid,
                 {:write, fn b -> Process.sleep(5_500) && {:slept, b} end},
                 15_000
               )}
            )
          end)

          Process.sleep(100)
          Ash.create(Herd, %{name: "Late", head: 9}, authorize?: false)
        end)

      assert %Error{reason: :timeout} = Error.find(error)

      assert_receive {:busy, {:ok, _, _}}, 10_000
      {:ok, changes} = Ramal.diff(branch)
      refute Enum.any?(changes, &(&1.key == "Late" or match?(%{record: %{name: "Late"}}, &1)))
      assert {:ok, branch_now} = Ramal.get(branch.id)
      refute Enum.any?(branch_now.log, fn {_, _, _, input, _, _, _} -> input[:name] == "Late" end)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
