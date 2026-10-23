defmodule Ramal.NestedBranchTest do
  # A fork made with `nested: true` merges into its parent branch, not into the database (ADR 0043). Each test names a
  # behaviour; none could pass before nested forks existed.
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ramal.BranchCase, only: [eventually: 1]

  alias Ramal.{Branch, Error}
  alias Ramal.Branch.Server
  alias Ramal.Storage.ETS

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, parent} = Ramal.branch(Farm, name: "parent")
    {:ok, child} = Ramal.fork(parent, nested: true, name: "child")
    {:ok, Map.merge(seeds, %{parent: parent, child: child})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp heads, do: Herd |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.head})
  defp heads_in(branch), do: inside(branch, &heads/0)

  defp update(branch, herd, attrs),
    do: inside(branch, fn -> Ash.update!(herd, attrs, authorize?: false) end)

  defp create(branch, name, head),
    do: inside(branch, fn -> Ash.create!(Herd, %{name: name, head: head}, authorize?: false) end)

  defp read(branch), do: inside(branch, fn -> Ash.read!(Herd, authorize?: false) end)

  defp merge(branch, opts \\ []),
    do: Ramal.merge(branch, Keyword.put_new(opts, :authorize?, false))

  describe "fork/2 with nested: true" do
    test "records the parent and how much of its log the fork inherited", %{
      parent: parent,
      herds: herds
    } do
      update(parent, herds.r7, %{head: 31})
      {:ok, child} = Ramal.fork(parent, nested: true)

      assert child.parent == %{id: parent.id, log_length: 1}
      assert child.metadata.forked_from == parent.id
      assert child.parent_seen == %{}
    end

    test "a plain fork of a nested fork is a sibling that merges into the database", %{
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 31})
      {:ok, sibling} = Ramal.fork(child)

      assert sibling.parent == nil
      assert {:ok, %{replayed: 1}} = merge(sibling)
      assert heads()["R7"] == 31
    end

    test "a nested fork of a nested fork is a branch of it", %{child: child} do
      {:ok, grandchild} = Ramal.fork(child, nested: true)
      assert grandchild.parent.id == child.id
    end

    test "counts against the limits like any fork" do
      stop_supervised!(Ramal.Supervisor)
      start_supervised!({Ramal.Supervisor, max_active_branches: 1})
      {:ok, parent} = Ramal.branch(Farm)

      assert {:error, %Error{reason: :limit_reached}} = Ramal.fork(parent, nested: true)
    end
  end

  describe "merge/2 of a nested fork" do
    test "the fork's writes reach the parent and not the database", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      create(child, "R10", 5)

      assert {:ok, %Ramal.Merge.Result{replayed: 2, stale: []}} = merge(child)

      assert heads_in(parent)["R7"] == 41
      assert heads_in(parent)["R10"] == 5
      assert heads()["R7"] == 30
      refute Map.has_key?(heads(), "R10")
      assert {:ok, %{status: :merged}} = Ramal.get(child.id)
    end

    test "only the entries the fork wrote itself are replayed, not the ones it inherited", %{
      parent: parent,
      herds: herds
    } do
      update(parent, herds.r7, %{head: 31})
      {:ok, child} = Ramal.fork(parent, nested: true)
      update(child, herds.r8, %{head: 36})

      assert {:ok, %{replayed: 1}} = merge(child)
      {:ok, merged_parent} = Ramal.get(parent.id)
      assert length(merged_parent.log) == 2
      assert heads_in(parent) |> Map.take(["R7", "R8"]) == %{"R7" => 31, "R8" => 36}
    end

    test "the parent merged to the database carries the fork's work", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(parent, herds.r8, %{head: 36})
      update(child, herds.r7, %{head: 41})
      create(child, "R10", 5)
      {:ok, _} = merge(child)

      assert {:ok, %{replayed: 3}} = merge(parent)
      assert %{"R7" => 41, "R8" => 36, "R10" => 5} = heads() |> Map.take(["R7", "R8", "R10"])
    end

    test "an unrelated write to the parent does not stop the merge", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      read(child)
      create(parent, "R10", 5)
      update(child, herds.r7, %{head: 41})

      assert {:ok, %{replayed: 1}} = merge(child)
      assert heads_in(parent) |> Map.take(["R7", "R10"]) == %{"R7" => 41, "R10" => 5}
    end

    test "a row the fork read and the parent changed since is stale", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      read(child)
      update(parent, herds.r7, %{head: 31})
      update(child, herds.r8, %{head: 36})

      assert {:error, %Error{reason: :stale, details: %{rows: [row]}}} = merge(child)
      assert %{resource: Herd, key: key, reason: :changed} = row
      assert key == herds.r7.id
      assert {:ok, %{status: :open}} = Ramal.get(child.id)
      assert heads_in(parent)["R8"] == 35
    end

    test "on_stale: :ignore merges a stale fork and reports the rows", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      read(child)
      update(parent, herds.r7, %{head: 31})
      update(child, herds.r8, %{head: 36})

      assert {:ok, %{replayed: 1, stale: [%{reason: :changed}]}} = merge(child, on_stale: :ignore)
      assert heads_in(parent) |> Map.take(["R7", "R8"]) == %{"R7" => 31, "R8" => 36}
    end

    test "a row the parent created and the fork read, changed again in the parent, is stale", %{
      parent: parent
    } do
      created = create(parent, "R10", 5)
      {:ok, child} = Ramal.fork(parent, nested: true)
      read(child)
      update(parent, created, %{head: 6})

      assert {:error, %Error{reason: :stale, details: %{rows: [%{key: key}]}}} = merge(child)
      assert key == created.id
    end

    test "a row the fork wrote and the parent destroyed since is stale as deleted", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      inside(parent, fn -> Ash.destroy!(herds.r7, authorize?: false) end)

      assert {:error, %Error{reason: :stale, details: %{rows: [%{reason: :deleted}]}}} =
               merge(child)
    end

    test "a failed replay leaves the parent as it was", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      create(child, "R10", 5)
      update(child, herds.r7, %{head: 41})
      inside(parent, fn -> Ash.destroy!(herds.r7, authorize?: false) end)
      {:ok, before_merge} = Ramal.get(parent.id)

      assert {:error, %Error{reason: :merge_failed, details: %{index: 1}}} =
               merge(child, on_stale: :ignore)

      {:ok, after_merge} = Ramal.get(parent.id)

      assert {after_merge.overlay, after_merge.log, after_merge.base} ==
               {before_merge.overlay, before_merge.log, before_merge.base}

      assert after_merge.merged_children == []
      assert {:ok, %{status: :open}} = Ramal.get(child.id)
      refute Map.has_key?(heads_in(parent), "R10")
    end

    test "a failed replay leaves no scratch branch behind", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      inside(parent, fn -> Ash.destroy!(herds.r7, authorize?: false) end)
      before = Registry.count(Ramal.Supervisor.registry())

      assert {:error, %Error{reason: :merge_failed}} = merge(child, on_stale: :ignore)
      eventually(fn -> Registry.count(Ramal.Supervisor.registry()) == before end)
      assert {:ok, stored} = ETS.list(Farm, [], [])
      assert Enum.sort(Enum.map(stored, & &1.id)) == Enum.sort([parent.id, child.id])
    end

    test "a second merge is refused", %{child: child, herds: herds} do
      update(child, herds.r7, %{head: 41})
      {:ok, _} = merge(child)

      assert {:error, %Error{reason: :not_open}} = merge(child)
    end

    test "a fork that is stored open after its parent adopted it is found merged and not merged twice",
         %{
           parent: parent,
           child: child,
           herds: herds
         } do
      create(child, "R10", 5)
      update(child, herds.r7, %{head: 41})
      {:ok, open_child} = Ramal.get(child.id)
      {:ok, _} = merge(child)

      # What a crash between the parent's persist and the child's own does: the child is stored as it was.
      :ok = ETS.put(open_child, [])

      assert {:error, %Error{reason: :not_open, details: %{status: :merged}}} = merge(child.id)
      assert {:ok, %{status: :merged}} = Ramal.get(child.id)
      {:ok, held} = Ramal.get(parent.id)
      assert held.merged_children == [child.id]
      assert Enum.count(heads_in(parent), fn {name, _} -> name == "R10" end) == 1
    end

    test "a fork stored open that its parent holds is merged when it is loaded and takes no writes",
         %{
           child: child,
           herds: herds
         } do
      update(child, herds.r7, %{head: 41})
      {:ok, open_child} = Ramal.get(child.id)
      {:ok, _} = merge(child)
      :ok = ETS.put(open_child, [])

      assert {:ok, %{status: :merged}} = Ramal.get(child.id)
      assert {:error, %Error{reason: :not_open}} = Ramal.run(child, fn -> :never end)
    end

    test "a fork whose merger died after the parent took its work is merged, so a later write is not lost",
         %{
           parent: parent,
           child: child,
           herds: herds
         } do
      update(child, herds.r7, %{head: 41})
      {:ok, source, version} = Server.merge_source(parent.id)
      {:ok, held} = Ramal.get(child.id)
      test = self()

      merger =
        spawn(fn ->
          {:ok, _claimed} = Server.begin_merge(child.id)
          :ok = Server.adopt(parent.id, Branch.scratch(source), held, version)
          send(test, {:adopted, self()})
        end)

      assert_receive {:adopted, ^merger}
      eventually(fn -> match?({:ok, %{status: :merged}}, ETS.fetch(child.id, [])) end)

      assert {:error, %Error{reason: :not_open}} = Ramal.run(child, fn -> :never end)
      assert {:ok, %{status: :merged}} = Ramal.get(child.id)
    end

    test "a row a hook created in the fork keeps its key in the parent, and a later action on it is replayed",
         %{
           parent: parent,
           child: child,
           herds: herds,
           paddocks: paddocks
         } do
      Ash.update!(paddocks.l18, %{capacity_head: 500}, authorize?: false)

      move =
        inside(child, fn ->
          Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id},
            action: :move_early,
            authorize?: false
          )

          [move] = Ash.read!(Move, authorize?: false)
          Ash.update!(move, %{moved_on: ~D[2026-01-01]}, authorize?: false)
        end)

      assert {:ok, %{replayed: 2}} = merge(child)

      assert [%{id: id, moved_on: ~D[2026-01-01]}] =
               inside(parent, fn -> Ash.read!(Move, authorize?: false) end)

      assert id == move.id
      assert Ash.read!(Move, authorize?: false) == []

      assert {:ok, %{replayed: 2}} = merge(parent, actor: %{role: :admin})
      assert [%{id: ^id, moved_on: ~D[2026-01-01]}] = Ash.read!(Move, authorize?: false)
    end

    test "a bulk update and a bulk create in the fork are replayed in the parent record by record",
         %{
           parent: parent,
           child: child
         } do
      inside(child, fn ->
        Ash.bulk_update!(Herd, :update, %{head: 1}, authorize?: false, strategy: [:stream])

        Ash.bulk_create!([%{name: "B1", head: 2}, %{name: "B2", head: 3}], Herd, :create,
          authorize?: false
        )
      end)

      assert {:ok, %{replayed: 5}} = merge(child)
      assert heads_in(parent) == %{"R7" => 1, "R8" => 1, "R9" => 1, "B1" => 2, "B2" => 3}
      assert heads() == %{"R7" => 30, "R8" => 35, "R9" => 25}

      assert {:ok, %{replayed: 5}} = merge(parent)
      assert heads() == %{"R7" => 1, "R8" => 1, "R9" => 1, "B1" => 2, "B2" => 3}
    end

    test "an attribute the caller set after building the changeset survives both merges", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      inside(child, fn ->
        herds.r7
        |> Ash.Changeset.for_update(:update, %{name: "R7b"}, authorize?: false)
        |> Ash.Changeset.force_change_attribute(:head, 99)
        |> Ash.update!()
      end)

      assert {:ok, %{replayed: 1}} = merge(child)
      assert heads_in(parent)["R7b"] == 99

      assert {:ok, %{replayed: 1}} = merge(parent)
      assert heads()["R7b"] == 99
    end

    test "an upsert in the fork is replayed in the parent as an upsert", %{
      parent: parent,
      child: child,
      paddocks: paddocks
    } do
      upsert = fn name, capacity ->
        Ash.create!(Paddock, %{name: name, capacity_head: capacity},
          action: :upsert,
          authorize?: false
        )
      end

      inside(child, fn ->
        upsert.(paddocks.l07.name, 120)
        upsert.("L99", 5)
      end)

      assert {:ok, %{replayed: 2}} = merge(child)

      capacities =
        inside(parent, fn ->
          Paddock |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.capacity_head})
        end)

      assert %{"L07" => 120, "L99" => 5} = capacities

      assert Paddock
             |> Ash.read!(authorize?: false)
             |> Enum.find(&(&1.name == "L07"))
             |> Map.fetch!(:capacity_head) == 100

      assert {:ok, %{replayed: 2}} = merge(parent)

      assert Paddock
             |> Ash.read!(authorize?: false)
             |> Enum.find(&(&1.name == "L07"))
             |> Map.fetch!(:capacity_head) == 120
    end

    test "approve of a proposed fork merges it into the parent", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      {:ok, _} = Ramal.propose(child, proposed_by: "ana")

      assert {:ok, %{branch: %{proposal: %{decision: %{status: :approved}}}}} =
               Ramal.approve(child, decided_by: "bo", authorize?: false)

      assert heads_in(parent)["R7"] == 41
      assert heads()["R7"] == 30
    end

    test "a fork of a fork merges up one level at a time", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      {:ok, grandchild} = Ramal.fork(child, nested: true)
      update(grandchild, herds.r7, %{head: 41})

      assert {:ok, %{replayed: 1}} = merge(grandchild)
      assert heads_in(child)["R7"] == 41
      assert heads_in(parent)["R7"] == 30

      assert {:ok, %{replayed: 1}} = merge(child)
      assert heads_in(parent)["R7"] == 41
      assert heads()["R7"] == 30
    end

    test "what a grandchild read stays protected after it merged into its parent", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      {:ok, grandchild} = Ramal.fork(child, nested: true)
      read(grandchild)
      update(grandchild, herds.r8, %{head: 36})
      {:ok, _} = merge(grandchild)
      update(parent, herds.r7, %{head: 31})

      assert {:error, %Error{reason: :stale, details: %{rows: rows}}} = merge(child)
      assert Enum.any?(rows, &(&1.key == herds.r7.id))
    end
  end

  describe "when the parent is not open" do
    test "a fork cannot merge into a parent that was merged to the database", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      {:ok, _} = merge(parent)

      assert {:error,
              %Error{reason: :parent_not_open, details: %{parent: parent_id, status: :merged}}} =
               merge(child)

      assert parent_id == parent.id
      assert {:ok, %{status: :open}} = Ramal.get(child.id)
      assert :ok = Ramal.discard(child)
    end

    test "a fork cannot merge into a discarded parent", %{parent: parent, child: child} do
      :ok = Ramal.discard(parent)

      assert {:error, %Error{reason: :parent_not_open, details: %{status: :discarded}}} =
               merge(child)
    end

    test "a fork cannot merge into a parent being merged", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      {:ok, _claimed} = Server.begin_merge(parent.id)

      assert {:error, %Error{reason: :parent_not_open, details: %{status: :merging}}} =
               merge(child)
    end
  end

  describe "the database staleness check" do
    test "a row the fork read and the database changed makes the parent stale when it merges", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      read(child)
      update(child, herds.r9, %{head: 26})
      Ash.update!(herds.r8, %{head: 99}, authorize?: false)
      {:ok, _} = merge(child)

      assert {:error, %Error{reason: :stale, details: %{rows: rows}}} = merge(parent)
      assert Enum.any?(rows, &(&1.key == herds.r8.id))
    end

    test "the fork's first fingerprint is kept, not the later one the replay took", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      Ash.update!(herds.r7, %{head: 99}, authorize?: false)
      {:ok, _} = merge(child, on_stale: :ignore)

      assert {:error, %Error{reason: :stale}} = merge(parent)
    end
  end

  describe "diff/2 against: :parent" do
    test "shows only what the fork wrote itself", %{parent: parent, herds: herds} do
      update(parent, herds.r7, %{head: 31})
      {:ok, child} = Ramal.fork(parent, nested: true)
      update(child, herds.r8, %{head: 36})
      created = create(child, "R10", 5)

      assert {:ok, changes} = Ramal.diff(child, against: :parent)

      assert changes |> Enum.map(&{&1.kind, &1.key}) == [
               {:updated, herds.r8.id},
               {:created, created.id}
             ]

      assert Enum.at(changes, 0).changes.head == {35, 36}
      assert {:ok, all} = Ramal.diff(child)
      assert length(all) == 3
    end

    test "compares with the parent's copy of a row the parent changed", %{
      parent: parent,
      herds: herds
    } do
      update(parent, herds.r7, %{head: 31})
      {:ok, child} = Ramal.fork(parent, nested: true)
      update(child, herds.r7, %{head: 32})

      assert {:ok, [change]} = Ramal.diff(child, against: :parent)
      assert change.changes.head == {31, 32}
    end

    test "a row the fork destroyed that the parent created is a delete", %{parent: parent} do
      created = create(parent, "R10", 5)
      {:ok, child} = Ramal.fork(parent, nested: true)
      inside(child, fn -> Ash.destroy!(created, authorize?: false) end)

      assert {:ok, [%{kind: :deleted, changes: %{name: {"R10", nil}}}]} =
               Ramal.diff(child, against: :parent)
    end

    test "a branch that is not a nested fork has no parent", %{parent: parent} do
      assert {:error, %Error{reason: :no_parent}} = Ramal.diff(parent, against: :parent)
    end
  end

  describe "branches stay apart" do
    test "run/2 inside run/2 is still refused", %{parent: parent, child: child} do
      result = Ramal.run!(parent, fn -> Ramal.run(child, fn -> :never end) end)

      assert {:error, %Error{reason: :nested_branch}} = result
    end

    test "the parent does not see the fork's writes before the merge", %{
      parent: parent,
      child: child
    } do
      create(child, "R10", 5)

      refute Map.has_key?(heads_in(parent), "R10")
    end

    test "the fork keeps what the parent held when it was forked", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(parent, herds.r7, %{head: 31})

      assert heads_in(child)["R7"] == 30
    end
  end

  describe "adopting" do
    test "the parent refuses a copy of itself that is not current", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      {:ok, source, version} = Server.merge_source(parent.id)
      update(parent, herds.r8, %{head: 36})
      scratch = Branch.scratch(source)

      assert {:error, :moved} = Server.adopt(parent.id, scratch, child, version)
      assert heads_in(parent)["R8"] == 36
    end

    test "a write to the parent during the replay is retried once", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      test = self()

      handler = fn _event, _measurements, %{branch_id: id}, _config ->
        if id == child.id, do: send(test, :merging)
      end

      :telemetry.attach("nested-merge", [:ramal, :merge, :start], handler, nil)
      on_exit(fn -> :telemetry.detach("nested-merge") end)

      task = Task.async(fn -> merge(child) end)
      assert_receive :merging
      update(parent, herds.r9, %{head: 26})

      assert {:ok, %{replayed: 1}} = Task.await(task)
      assert heads_in(parent) |> Map.take(["R7", "R9"]) == %{"R7" => 41, "R9" => 26}
    end

    test "persists the parent with the fork's work before the fork is marked merged", %{
      parent: parent,
      child: child,
      herds: herds
    } do
      update(child, herds.r7, %{head: 41})
      {:ok, _} = merge(child)

      assert {:ok, stored} = ETS.fetch(parent.id, [])
      assert stored.merged_children == [child.id]
      assert {:updated, %{head: 41}} = stored.overlay[{Herd, herds.r7.id}]
    end
  end

  describe "a fork unloaded and loaded again" do
    test "keeps its parent and what it saw", %{parent: parent, child: child, herds: herds} do
      read(child)
      update(child, herds.r7, %{head: 41})
      {:ok, before_unload} = Ramal.get(child.id)
      pid = Ramal.Supervisor.whereis(child.id)
      GenServer.stop(pid, :normal)
      refute Ramal.Supervisor.whereis(child.id)

      {:ok, loaded} = Ramal.get(child.id)
      assert loaded.parent == before_unload.parent
      assert loaded.parent_seen == before_unload.parent_seen
      update(parent, herds.r7, %{head: 31})
      assert {:error, %Error{reason: :stale}} = merge(child)
    end
  end
end
