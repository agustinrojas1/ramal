defmodule Ramal.MergeEntriesTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  alias Ramal.Merge.Result

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp reload!(herd), do: Ash.get!(Herd, herd.id, authorize?: false)

  describe "the :context option" do
    test "reaches the changeset of every replayed action", %{branch: branch, herds: herds} do
      Ramal.run!(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, action: :annotate, authorize?: false)
      end)

      assert {:ok, %Result{replayed: 1}} =
               Ramal.merge(branch, authorize?: false, context: %{name: "from the host"})

      assert reload!(herds.r7).name == "from the host"
    end

    test "is set by approve/2 too", %{branch: branch, herds: herds} do
      Ramal.run!(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, action: :annotate, authorize?: false)
      end)

      {:ok, _} = Ramal.propose(branch, proposed_by: "ana", reason: "count")

      assert {:ok, %Result{replayed: 1}} =
               Ramal.approve(branch,
                 decided_by: "bo",
                 reason: "ok",
                 authorize?: false,
                 context: %{name: "approved"}
               )

      assert reload!(herds.r7).name == "approved"
    end

    test "a replayed action sees no context when none is given", %{branch: branch, herds: herds} do
      Ramal.run!(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, action: :annotate, authorize?: false)
      end)

      assert {:ok, %Result{}} = Ramal.merge(branch, authorize?: false)
      assert reload!(herds.r7).name == herds.r7.name
    end

    test "must be a map", %{branch: branch} do
      assert_raise ArgumentError, ~r/`context` must be a map/, fn ->
        Ramal.merge(branch, context: [name: "x"])
      end
    end
  end

  describe "Result.entries" do
    test "lists every replayed write in log order, with the record and its metadata", %{
      branch: branch,
      herds: herds
    } do
      Ramal.run!(branch, fn ->
        r7 = Ash.update!(herds.r7, %{head: 31}, action: :annotate, authorize?: false)
        Ash.update!(r7, %{head: 32}, action: :annotate, authorize?: false)
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
      end)

      assert {:ok, %Result{replayed: 3, records: records, entries: entries}} =
               Ramal.merge(branch, authorize?: false, context: %{request_id: "req-1"})

      assert map_size(records) == 2
      assert [first, second, third] = entries
      assert Enum.map(entries, & &1.index) == [0, 1, 2]
      assert Enum.map(entries, & &1.type) == [:update, :update, :create]
      assert [Herd, Herd, Herd] = Enum.map(entries, & &1.resource)
      assert [:annotate, :annotate, :create] = Enum.map(entries, & &1.action)
      assert [31, 32] == [first.record.head, second.record.head]
      assert first.key == herds.r7.id and second.key == herds.r7.id
      assert %{request_id: "req-1"} = first.metadata
      assert third.record.name == "R10" and third.key == third.record.id
      refute Map.has_key?(third.metadata, :request_id)
    end

    test "lists a destroy as :deleted", %{branch: branch, herds: herds} do
      Ramal.run!(branch, fn -> Ash.destroy!(herds.r7, authorize?: false) end)

      assert {:ok, %Result{entries: [entry]}} = Ramal.merge(branch, authorize?: false)
      assert %{type: :destroy, record: :deleted, key: key} = entry
      assert key == herds.r7.id
    end

    test "is empty for a branch with no writes", %{branch: branch} do
      assert {:ok, %Result{entries: [], replayed: 0}} = Ramal.merge(branch, authorize?: false)
    end
  end
end
