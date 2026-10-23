defmodule Ramal.BulkTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  #
  # Inside a branch a bulk action runs one record at a time through the captured action, because the capture hook is an
  # `around_action` and Ash runs such changesets singly (`split_and_run_simple/7` in deps/ash/lib/ash/actions/helpers.ex).
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Merge.Result

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp state(branch), do: elem(Ramal.get(branch.id), 1)
  defp db_heads, do: Herd |> Ash.read!(authorize?: false) |> Map.new(&{&1.name, &1.head})
  defp heads, do: db_heads()
  defp log_actions(branch), do: branch |> state() |> Map.fetch!(:log) |> Enum.map(&elem(&1, 0))

  @base %{"R7" => 30, "R8" => 35, "R9" => 25}

  describe "Ash.bulk_create/4" do
    test "creates the rows in the branch only, one logged create per record", %{branch: branch} do
      result =
        inside(branch, fn ->
          Ash.bulk_create([%{name: "B1", head: 1}, %{name: "B2", head: 2}], Herd, :create,
            authorize?: false,
            return_errors?: true,
            return_records?: true
          )
        end)

      assert %Ash.BulkResult{status: :success, records: records} = result
      assert records |> Enum.map(& &1.name) |> Enum.sort() == ["B1", "B2"]
      assert inside(branch, &heads/0) == Map.merge(@base, %{"B1" => 1, "B2" => 2})
      assert db_heads() == @base
      assert log_actions(branch) == [:create, :create]
      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch)
      assert db_heads() == Map.merge(@base, %{"B1" => 1, "B2" => 2})
    end

    test "with max_concurrency the records created in tasks are captured too", %{branch: branch} do
      for opts <- [[max_concurrency: 2, batch_size: 1], [max_concurrency: 4, batch_size: 2]] do
        result =
          inside(branch, fn ->
            Ash.bulk_create(
              [%{name: "C1", head: 1}, %{name: "C2", head: 1}, %{name: "C3", head: 1}],
              Herd,
              :create,
              [authorize?: false, return_errors?: true] ++ opts
            )
          end)

        assert result.status == :success
      end

      assert db_heads() == @base
      assert length(state(branch).log) == 6
      assert map_size(state(branch).overlay) == 6
    end

    test "a record that fails validation leaves no row and the others are captured", %{
      branch: branch
    } do
      result =
        inside(branch, fn ->
          Ash.bulk_create([%{name: "B1", head: 1}, %{name: nil, head: 2}], Herd, :create,
            authorize?: false,
            return_errors?: true
          )
        end)

      assert %Ash.BulkResult{status: :partial_success, error_count: 1} = result
      assert inside(branch, &heads/0) == Map.put(@base, "B1", 1)
      assert db_heads() == @base
      assert log_actions(branch) == [:create]
    end

    test "with a transaction for all records, one failure takes every record back", %{
      branch: branch
    } do
      result =
        inside(branch, fn ->
          Ash.bulk_create([%{name: "B1", head: 1}, %{name: nil, head: 2}], Herd, :create,
            authorize?: false,
            return_errors?: true,
            transaction: :all,
            rollback_on_error?: true,
            stop_on_error?: true
          )
        end)

      assert %Ash.BulkResult{status: :error} = result
      assert db_heads() == @base

      # The transaction is the data layer's: rolling it back takes back nothing in the branch, where the first record
      # was captured as a completed action. That is what a branch can promise: the records that succeeded are there.
      assert Map.delete(inside(branch, &heads/0), "B1") == @base
    end

    test "outside a branch still writes through the data layer's bulk insert" do
      result =
        Ash.bulk_create([%{name: "B1", head: 1}], Herd, :create,
          authorize?: false,
          return_errors?: true
        )

      assert result.status == :success
      assert db_heads() == Map.put(@base, "B1", 1)
    end
  end

  describe "Ash.bulk_update/4" do
    test "of a query with the stream strategy updates the branch's view of each row", %{
      branch: branch
    } do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "NEW", head: 7}, authorize?: false)

        result =
          Herd
          |> Ash.Query.filter(head < 31)
          |> Ash.bulk_update(:update, %{head: 1},
            authorize?: false,
            strategy: [:atomic, :stream],
            return_errors?: true
          )

        assert result.status == :success
      end)

      assert inside(branch, &heads/0) == %{"R7" => 1, "R8" => 35, "R9" => 1, "NEW" => 1}
      assert db_heads() == @base
      assert log_actions(branch) |> Enum.sort() == [:create, :update, :update, :update]

      assert {:ok, %Result{replayed: 4}} = Ramal.merge(branch)
      assert db_heads() == %{"R7" => 1, "R8" => 35, "R9" => 1, "NEW" => 1}
    end

    test "of a list of records updates each one in the branch", %{branch: branch, herds: herds} do
      result =
        inside(branch, fn ->
          Ash.bulk_update([herds.r7, herds.r8], :update, %{head: 2},
            authorize?: false,
            strategy: [:stream],
            return_errors?: true,
            return_records?: true
          )
        end)

      assert result.status == :success
      assert result.records |> Enum.map(& &1.head) == [2, 2]
      assert inside(branch, &heads/0) == %{"R7" => 2, "R8" => 2, "R9" => 25}
      assert db_heads() == @base
    end

    # Ash picks the strategy before any hook runs, and inside a branch neither atomic strategy can be used: the read
    # preparation has a `before_action` hook and the capture's `atomic/3` answers `:not_atomic`.
    test "with only the atomic strategy is refused and writes nothing", %{
      branch: branch
    } do
      result =
        inside(branch, fn ->
          Ash.bulk_update(Herd, :update, %{head: 1}, authorize?: false, return_errors?: true)
        end)

      assert %Ash.BulkResult{status: :error, errors: [error]} = result
      assert Exception.message(error) =~ "Could not use `:stream`: Not in requested strategies"
      assert inside(branch, &heads/0) == @base
      assert db_heads() == @base
      assert state(branch).overlay == %{}
    end
  end

  describe "Ash.bulk_destroy/4" do
    test "of a query destroys the rows in the branch only", %{branch: branch} do
      result =
        inside(branch, fn ->
          Herd
          |> Ash.Query.filter(name in ["R7", "R9"])
          |> Ash.bulk_destroy(:destroy, %{},
            authorize?: false,
            strategy: [:stream],
            return_errors?: true
          )
        end)

      assert result.status == :success
      assert inside(branch, &heads/0) == %{"R8" => 35}
      assert db_heads() == @base
      assert {:ok, %Result{replayed: 2}} = Ramal.merge(branch)
      assert db_heads() == %{"R8" => 35}
    end

    test "of a row the branch created leaves no entry", %{branch: branch} do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "TMP", head: 1}, authorize?: false)

        Herd
        |> Ash.Query.filter(name == "TMP")
        |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, strategy: [:stream])
      end)

      assert inside(branch, &heads/0) == @base
      assert state(branch).overlay == %{}
    end
  end

  describe "the guard" do
    # Ash runs every changeset with an `around_action` hook singly. Should a path ever run the before-action hooks
    # without it, the capture refuses the action rather than let the data layer write the row.
    test "an action whose capture hook did not wrap it is refused and writes nothing", %{
      branch: branch
    } do
      result =
        inside(branch, fn ->
          changeset =
            Ash.Changeset.for_create(Herd, :create, %{name: "X", head: 1}, authorize?: false)

          Ash.create(%{changeset | around_action: []}, authorize?: false)
        end)

      assert {:error, error} = result
      assert %Ramal.Error{reason: :bulk_unsupported} = Ramal.Error.find(error)
      assert db_heads() == @base
      assert state(branch).overlay == %{}
    end
  end
end
