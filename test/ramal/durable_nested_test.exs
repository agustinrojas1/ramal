defmodule Ramal.DurableNestedTest do
  # Durable branches (ADR 0048) with nested forks (ADR 0043): the work a fork gives its parent is stored when the parent
  # answers, once, and the parent's own actions go on appending after it.
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [eventually: 1, loaded?: 1]

  alias Ramal.{Branch, Error}
  alias Ramal.Branch.Server
  alias Ramal.Storage.ETS
  alias Ramal.Test.Capture
  alias Ramal.Test.Capture.{Gated, Silent}

  setup do
    start_supervised!({Ramal.Supervisor, durable: true})
    seeds = Seeds.seed!()
    {:ok, parent} = Ramal.branch(Farm, name: "parent")
    {:ok, child} = Ramal.fork(parent, nested: true, name: "child")
    {:ok, Map.merge(seeds, %{parent: parent, child: child})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp state(id), do: elem(Ramal.get(id), 1)
  defp heads, do: Herd |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.head})
  defp heads_in(branch), do: inside(branch, &heads/0)
  defp merge(branch), do: Ramal.merge(branch, authorize?: false)

  defp update(branch, herd, attrs),
    do: inside(branch, fn -> Ash.update!(herd, attrs, authorize?: false) end)

  defp create(branch, name, head),
    do: inside(branch, fn -> Ash.create!(Herd, %{name: name, head: head}, authorize?: false) end)

  defp deltas(branch_id) do
    {:ok, deltas} =
      ETS.writes_after(%Branch{id: branch_id, domain: Farm, inserted_at: DateTime.utc_now()}, [])

    deltas
  end

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

  describe "a nested fork merged into a durable parent" do
    test "is in the parent exactly once after the parent is killed and loaded again", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(parent, herds.r8, %{head: 36})
      create(child, "R10", 5)
      update(child, herds.r7, %{head: 41})

      assert {:ok, %{replayed: 2}} = merge(child)
      update(parent, herds.r9, %{head: 26})
      before = state(parent.id)
      assert before.merged_children == [child.id]

      crash(parent.id)
      recovered = state(parent.id)

      assert recovered.overlay == before.overlay
      assert recovered.log == before.log
      assert recovered.merged_children == [child.id]
      assert length(recovered.log) == 4
      assert recovered.wal == before.wal

      names = heads_in(parent)

      assert names |> Map.take(["R7", "R8", "R9", "R10"]) == %{
               "R7" => 41,
               "R8" => 36,
               "R9" => 26,
               "R10" => 5
             }

      assert Enum.count(recovered.log, &(elem(&1, 3)[:name] == "R10")) == 1
    end

    test "is stored as a snapshot that covers the log so far, and later actions append after it",
         %{
           parent: parent,
           child: child,
           herds: herds
         } do
      update(parent, herds.r8, %{head: 36})
      update(child, herds.r7, %{head: 41})
      assert Enum.map(deltas(parent.id), &elem(&1, 0)) == [1]

      {:ok, _} = merge(child)

      assert deltas(parent.id) == []
      assert {:ok, %{wal: 1, merged_children: [id]}} = ETS.fetch(parent.id, [])
      assert id == child.id

      update(parent, herds.r9, %{head: 26})
      assert Enum.map(deltas(parent.id), &elem(&1, 0)) == [2]
    end

    test "uses a scratch copy that stores nothing", %{child: child, herds: herds} do
      update(child, herds.r7, %{head: 41})
      {:ok, _} = merge(child)

      ids =
        :ets.tab2list(ETS.writes_table()) |> Enum.map(fn {{id, _seq}, _} -> id end) |> Enum.uniq()

      assert Enum.all?(ids, &(&1 in [child.id]))
      assert {:ok, %{status: :merged}} = Ramal.get(child.id)
    end

    test "is found merged by a fork stored open after the durable parent crashed", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      {:ok, open_child} = Ramal.get(child.id)
      {:ok, _} = merge(child)

      # What a crash between the parent's persist and the child's own leaves: the child stored as it was.
      :ok = ETS.put(open_child, [])
      update(parent, herds.r9, %{head: 26})
      crash(parent.id)

      assert {:ok, %{status: :merged}} = Ramal.get(child.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.run(child, fn -> :never end)
      assert state(parent.id).merged_children == [child.id]
    end
  end

  describe "a durable nested fork" do
    test "keeps its writes, its parent and what it saw of the rows it wrote after a kill", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      create(child, "R10", 5)
      before = state(child.id)
      assert before.durable and before.parent.id == parent.id

      crash(child.id)
      recovered = state(child.id)

      assert recovered.parent == before.parent
      assert recovered.parent_seen == before.parent_seen
      assert recovered.overlay == before.overlay
      assert recovered.log == before.log

      update(parent, herds.r7, %{head: 31})
      assert {:error, %Error{reason: :stale}} = merge(child)
    end

    test "merges after a kill into its parent", %{parent: parent, child: child, herds: herds} do
      update(child, herds.r7, %{head: 41})
      crash(child.id)

      assert {:ok, %{replayed: 1}} = merge(child)
      assert heads_in(parent)["R7"] == 41
    end
  end

  describe "an action of the parent while its fork merges" do
    # Gated holds an action between its write and its end, until the test lets it pass.
    test "makes the adopt move, and is neither lost nor applied twice", _context do
      Process.register(self(), :ramal_test_gate)
      {:ok, parent} = Ramal.branch(Capture)
      {:ok, child} = Ramal.fork(parent, nested: true)

      Ramal.run!(child, fn -> Ash.create!(Silent, %{text: "from the fork"}, authorize?: false) end)

      {:ok, source, version} = Server.merge_source(parent.id)
      test = self()

      action =
        spawn(fn ->
          send(
            test,
            {:ended, self(),
             Ramal.run(parent, fn -> Ash.create(Gated, %{text: "held"}, action: :gated_create) end)}
          )
        end)

      assert_receive {:at_gate, ^action}, 1_000
      Process.unregister(:ramal_test_gate)
      {:ok, held} = Ramal.get(child.id)

      assert {:error, :moved} = Server.adopt(parent.id, Branch.scratch(source), held, version)
      assert state(parent.id).merged_children == []

      send(action, {:gate, :pass})
      assert_receive {:ended, ^action, {:ok, {:ok, _}}}
      assert {:ok, %{replayed: 1}} = merge(child)

      before = state(parent.id)
      crash(parent.id)
      recovered = state(parent.id)

      assert recovered.overlay == before.overlay
      assert recovered.log == before.log
      assert recovered.merged_children == [child.id]

      texts =
        for {{resource, _}, {_kind, record}} <- recovered.overlay,
            resource in [Gated, Silent],
            do: record.text

      assert Enum.sort(texts) == ["from the fork", "held"]
      assert length(recovered.log) == 2
    end

    test "that starts after the copy was taken is not stored by the adopt", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      {:ok, source, version} = Server.merge_source(parent.id)
      {:ok, held} = Ramal.get(child.id)

      update(parent, herds.r9, %{head: 26})

      assert {:error, :moved} = Server.adopt(parent.id, Branch.scratch(source), held, version)
      assert Enum.map(deltas(parent.id), &elem(&1, 0)) == [1]
      assert {:ok, %{merged_children: []}} = ETS.fetch(parent.id, [])
    end
  end
end
