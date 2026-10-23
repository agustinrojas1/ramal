defmodule Ramal.MergeTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Branch.Server
  alias Ramal.Error
  alias Ramal.Merge.Result

  @admin %{role: :admin}

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp db_names, do: Herd |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()
  defp reload!(herd), do: Ash.get!(Herd, herd.id, authorize?: false)

  # The SELECT statements on the herds table that `fun` makes.
  defp count_selects(fun) do
    test = self()
    handler = "selects-#{inspect(test)}"

    :telemetry.attach(
      handler,
      [:ramal, :test_repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if query =~ ~r/^SELECT .* FROM "herds"/, do: send(test, :select)
      end,
      nil
    )

    try do
      fun.()
      drain(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(count) do
    receive do
      :select -> drain(count + 1)
    after
      0 -> count
    end
  end

  describe "a clean merge" do
    test "writes exactly the rows the diff promised", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.destroy!(herds.r9, authorize?: false)
        Ash.update!(herds.r8, %{paddock_id: paddocks.l18.id}, authorize?: false, action: :update)
      end)

      {:ok, changes} = Ramal.diff(branch)

      assert {:ok, %Result{replayed: 4, stale: []} = result} =
               Ramal.merge(branch, authorize?: false)

      assert db_names() == ["R10", "R7", "R8"]
      assert reload!(herds.r7).head == 31
      assert reload!(herds.r8).paddock_id == paddocks.l18.id

      # The result names the same rows, with the same kinds of change, as the diff did.
      promised = Enum.map(changes, &{&1.kind, &1.resource, &1.key})
      written = for {{resource, key}, entry} <- result.records, do: {kind(entry), resource, key}
      assert Enum.sort(promised) == Enum.sort(written)
    end

    test "the replay reuses the rows the staleness check read instead of reading each one again",
         %{
           branch: branch,
           herds: herds
         } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.update!(herds.r8, %{head: 36}, authorize?: false)
        Ash.destroy!(herds.r9, authorize?: false)
      end)

      selects =
        count_selects(fn ->
          assert {:ok, %Result{replayed: 3}} = Ramal.merge(branch, authorize?: false)
        end)

      # One read of the three rows for the staleness check; the replay does not fetch them again.
      assert selects == 1
      assert reload!(herds.r7).head == 31
      assert reload!(herds.r8).head == 36
      assert db_names() == ["R7", "R8"]
    end

    test "a row changed twice is read again for the second change, so both land", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        updated = Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.update!(updated, %{name: "R7b"}, authorize?: false)
        Ash.update!(herds.r8, %{head: 36}, authorize?: false)
      end)

      assert {:ok, %Result{replayed: 3}} = Ramal.merge(branch, authorize?: false)
      assert %{name: "R7b", head: 31} = reload!(herds.r7)
      assert reload!(herds.r8).head == 36
    end

    test "a created row keeps the primary key it had in the branch", %{branch: branch} do
      created =
        inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)

      assert {:ok, _} = Ramal.merge(branch, authorize?: false)
      assert Ash.get!(Herd, created.id, authorize?: false).name == "R10"
    end

    test "the branch is merged, its process stops, and it cannot be merged again", %{
      branch: branch
    } do
      inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)
      assert {:ok, %Result{branch: %{status: :merged}}} = Ramal.merge(branch, authorize?: false)

      assert {:ok, merged} = Ramal.get(branch.id)
      assert merged.status == :merged
      assert {:error, %Error{reason: :not_open}} = Ramal.merge(branch, authorize?: false)
      assert db_names() == ["R10", "R7", "R8", "R9"]
    end

    test "an empty branch merges without writing anything", %{branch: branch} do
      assert {:ok, %Result{replayed: 0, records: records}} = Ramal.merge(branch)
      assert records == %{}
    end

    test "a write made by a hook of another action is not replayed twice", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)
      end)

      assert {:ok, %Result{replayed: 1}} = Ramal.merge(branch)
      assert reload!(herds.r7).paddock_id == paddocks.l18.id
      assert [_one] = Move |> Ash.read!(authorize?: false)
    end

    test "the :actor option overrides the recorded actor, and policies then apply", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)
      end)

      assert {:error, %Error{reason: :merge_failed}} =
               Ramal.merge(branch, actor: %{role: :member})

      assert reload!(herds.r7).paddock_id == herds.r7.paddock_id
    end
  end

  describe "a stale base" do
    setup %{branch: branch, herds: herds} do
      inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      Ash.update!(herds.r7, %{head: 99}, authorize?: false)
      :ok
    end

    test "is refused by default and names the rows", %{branch: branch, herds: herds} do
      assert {:error, %Error{reason: :stale, details: %{rows: [row]}}} =
               Ramal.merge(branch, authorize?: false)

      assert row == %{resource: Herd, key: herds.r7.id, reason: :changed}
      assert reload!(herds.r7).head == 99
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    end

    test "is accepted with on_stale: :ignore and reported in the result", %{
      branch: branch,
      herds: herds
    } do
      assert {:ok, %Result{stale: [%{key: key, reason: :changed}]}} =
               Ramal.merge(branch, authorize?: false, on_stale: :ignore)

      assert key == herds.r7.id
      assert reload!(herds.r7).head == 31
    end

    test "can be decided by a function", %{branch: branch} do
      assert {:error, %Error{reason: :stale}} =
               Ramal.merge(branch,
                 authorize?: false,
                 on_stale: fn [%{reason: :changed}] -> :abort end
               )

      assert {:ok, _} =
               Ramal.merge(branch, authorize?: false, on_stale: fn _rows -> :continue end)
    end
  end

  test "a row deleted in the base is reported as deleted", %{branch: branch, herds: herds} do
    inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
    Ash.destroy!(herds.r7, authorize?: false)

    assert {:error, %Error{reason: :stale, details: %{rows: [%{reason: :deleted}]}}} =
             Ramal.merge(branch, authorize?: false)
  end

  test "a row only read in the branch is also checked", %{branch: branch, herds: herds} do
    inside(branch, fn -> Ash.read!(Herd, authorize?: false) end)
    Ash.update!(herds.r8, %{head: 1}, authorize?: false)

    assert {:error, %Error{reason: :stale, details: %{rows: [%{key: key}]}}} =
             Ramal.merge(branch, authorize?: false)

    assert key == herds.r8.id
  end

  describe "a failure while replaying" do
    test "aborts the transaction and leaves the base untouched", %{branch: branch, herds: herds} do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
      end)

      # Another writer deletes the row the branch updated; `on_stale: :ignore` lets the replay reach the failing update.
      Ash.destroy!(herds.r7, authorize?: false)

      assert {:error, %Error{reason: reason}} =
               Ramal.merge(branch, authorize?: false, on_stale: :ignore)

      assert reason == :merge_failed
      assert db_names() == ["R8", "R9"]
    end

    test "names the log entry that failed and keeps the branch open", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)
      end)

      # R9 already uses 25 of the 60 head of L18; a merge-time capacity check now sees 25 + 30 + 10 > 60.
      Ash.create!(Herd, %{name: "R11", head: 10, paddock_id: paddocks.l18.id}, authorize?: false)
      Ash.create!(Herd, %{name: "R12", head: 10, paddock_id: paddocks.l18.id}, authorize?: false)

      assert {:error, %Error{reason: :merge_failed, details: details}} = Ramal.merge(branch)
      assert %{index: 1, type: :update, resource: Herd, action: :move} = details
      assert "R10" not in db_names()
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    end
  end

  describe "on a data layer that cannot roll back (ETS)" do
    alias Ramal.Test.Ets
    alias Ramal.Test.Other.Note

    setup do
      on_exit(fn -> Ets.reset(Note) end)
      kept = Ash.create!(Note, %{text: "kept"})
      moved = Ash.create!(Note, %{text: "moved"})
      {:ok, branch} = Ramal.branch(Ramal.Test.Other)
      {:ok, branch: branch, kept: kept, moved: moved}
    end

    defp note_texts, do: Note |> Ash.read!() |> Enum.map(& &1.text) |> Enum.sort()

    test "a stale base is returned as an error and nothing is written", %{
      branch: branch,
      moved: moved
    } do
      inside(branch, fn -> Ash.update!(moved, %{text: "branch"}) end)
      Ash.update!(moved, %{text: "outside"})

      assert {:error, %Error{reason: :stale, details: %{rows: [%{reason: :changed}]}}} =
               Ramal.merge(branch)

      assert note_texts() == ["kept", "outside"]
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    end

    test "a failed replay is returned as an error, and says what stays written", %{
      branch: branch,
      moved: moved
    } do
      inside(branch, fn ->
        Ash.create!(Note, %{text: "new"})
        Ash.update!(moved, %{text: "branch"})
      end)

      Ash.destroy!(moved)

      assert {:error, %Error{reason: :merge_failed, message: message, details: details}} =
               Ramal.merge(branch, on_stale: :ignore)

      assert %{index: 1, type: :update, resource: Note, not_rolled_back: [Note]} = details
      assert message =~ "stay written"
      # ETS has no transactions: the create replayed before the failure is still in the table.
      assert note_texts() == ["kept", "new"]
      assert {:ok, %{status: :open}} = Ramal.get(branch.id)
    end

    test "a failure before anything was written has nothing to report", %{
      branch: branch,
      moved: moved
    } do
      inside(branch, fn -> Ash.update!(moved, %{text: "branch"}) end)
      Ash.destroy!(moved)

      assert {:error, %Error{reason: :merge_failed, message: message, details: details}} =
               Ramal.merge(branch, on_stale: :ignore)

      assert details.not_rolled_back == []
      assert message =~ "nothing was written"
    end

    test "a clean merge still works", %{branch: branch, moved: moved} do
      inside(branch, fn -> Ash.update!(moved, %{text: "branch"}) end)

      assert {:ok, %Result{replayed: 1}} = Ramal.merge(branch)
      assert note_texts() == ["branch", "kept"]
    end
  end

  describe "refusals" do
    test "inside a branch", %{branch: branch} do
      inside(branch, fn ->
        assert {:error, %Error{reason: :nested_branch}} = Ramal.merge(branch)
      end)
    end

    test "of a discarded branch", %{branch: branch} do
      :ok = Ramal.discard(branch)
      assert {:error, %Error{}} = Ramal.merge(branch)
    end

    test "of an unknown mode", %{branch: branch} do
      assert_raise ArgumentError, ~r/mode: :replay/, fn ->
        Ramal.merge(branch, mode: :snapshot)
      end
    end

    test "of a bad on_stale", %{branch: branch} do
      assert_raise ArgumentError, ~r/on_stale/, fn ->
        Ramal.merge(branch, on_stale: :sometimes)
      end
    end

    test "writes to a branch while it is being merged", %{branch: branch} do
      {:ok, _} = Server.begin_merge(branch.id)

      assert {:error, %Error{reason: :not_open}} =
               Server.write(branch.id, &{:x, &1})

      assert {:error, %Error{reason: :not_open}} = Ramal.discard(branch)
      :ok = Server.finish_merge(branch.id, :aborted)
      assert :ok = Ramal.discard(branch)
    end
  end

  test "a branch cannot be forked while a merge holds it", %{branch: branch} do
    inside(branch, fn -> Ash.create!(Herd, %{name: "X", head: 1}, authorize?: false) end)
    {:ok, _} = Server.begin_merge(branch.id)

    assert {:error, %Error{reason: :not_open}} = Ramal.fork(branch)
    assert {:ok, [_only_the_parent]} = Ramal.list(Farm)

    :ok = Server.finish_merge(branch.id, :aborted)
    assert {:ok, _fork} = Ramal.fork(branch)
  end

  test "emits start and stop telemetry with the outcome", %{branch: branch} do
    test = self()

    :telemetry.attach_many(
      "merge-events",
      [[:ramal, :merge, :start], [:ramal, :merge, :stop]],
      fn event, _m, meta, _ -> send(test, {:telemetry, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("merge-events") end)

    inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)
    {:ok, _} = Ramal.merge(branch, authorize?: false)

    id = branch.id
    domain = branch.domain
    assert_receive {:telemetry, [:ramal, :merge, :start], %{branch_id: ^id, domain: ^domain}}

    assert_receive {:telemetry, [:ramal, :merge, :stop],
                    %{result: :ok, replayed: 1, domain: ^domain}}
  end

  test "a merge receives the branch from its process once", %{branch: branch} do
    inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)

    # Every copy of the branch that reaches the caller is a reply of the process that holds a Ramal.Branch.
    :erlang.trace(Ramal.Supervisor.whereis(branch.id), true, [:send])
    {:ok, _} = Ramal.merge(branch, authorize?: false)

    replies =
      Stream.repeatedly(fn ->
        receive do
          {:trace, _pid, :send, {_tag, {:ok, %Ramal.Branch{}}}, _to} -> :branch
          {:trace, _pid, :send, _message, _to} -> :other
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    assert Enum.count(replies, &(&1 == :branch)) == 1
  end

  defp kind({:created, _}), do: :created
  defp kind({:updated, _}), do: :updated
  defp kind(:deleted), do: :deleted
end
