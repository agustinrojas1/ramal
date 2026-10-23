defmodule Ramal.CaptureTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ash.Resource.Info
  alias Ramal.Test.Capture.{Announced, Counter, Flaky, Silent, Ticket}

  @admin %{role: :admin}
  @member %{role: :member}

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)
  defp state(branch), do: elem(Ramal.get(branch.id), 1)
  defp db_names, do: Herd |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()
  defp names(herds), do: herds |> Enum.map(& &1.name) |> Enum.sort()

  defp reason_of(error), do: error |> Ramal.Error.find() |> Map.fetch!(:reason)

  describe "outside a branch" do
    test "writes reach the database exactly as before", %{herds: herds} do
      created = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
      Ash.update!(herds.r7, %{head: 31}, authorize?: false)
      Ash.destroy!(herds.r9, authorize?: false)

      assert db_names() == ["R10", "R7", "R8"]
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 31
      assert Ash.get!(Herd, created.id, authorize?: false).name == "R10"
    end

    test "the update and destroy actions of a resource that uses the extension can fall back from the atomic path" do
      for {type, name} <- [{:update, :update}, {:destroy, :destroy}] do
        action = Info.action(Herd, name, type)
        assert action.require_atomic? == false
      end
    end

    test "an atomic bulk update still runs in the database", %{herds: herds} do
      result =
        Ash.bulk_update(Herd, :update, %{head: 1},
          authorize?: false,
          strategy: :atomic,
          return_errors?: true
        )

      assert %Ash.BulkResult{status: :success} = result
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 1
    end

    test "the write capture adds no state to the process" do
      Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
      assert Process.get(:ramal_capture_frame) == nil
    end
  end

  describe "create" do
    test "a create that manages a belongs_to stores the new row's foreign key", %{branch: branch} do
      {herd, read_back, paddock_names} =
        inside(branch, fn ->
          herd =
            Herd
            |> Ash.Changeset.for_create(:create, %{name: "NEW", head: 3}, authorize?: false)
            |> Ash.Changeset.manage_relationship(:paddock, %{name: "NP", capacity_head: 9},
              type: :create
            )
            |> Ash.create!(authorize?: false)

          read_back = Herd |> Ash.read!(authorize?: false) |> Enum.find(&(&1.name == "NEW"))
          {herd, read_back, Paddock |> Ash.read!(authorize?: false) |> Enum.map(& &1.name)}
        end)

      assert herd.paddock_id
      assert read_back.paddock_id == herd.paddock_id
      assert "NP" in paddock_names

      assert {:ok, changes} = Ramal.diff(branch)
      herd_change = Enum.find(changes, &(&1.resource == Herd))
      assert herd_change.changes.paddock_id == {nil, herd.paddock_id}
    end

    test "a create action that manages a belongs_to merges with the new row's foreign key", %{
      branch: branch
    } do
      herd =
        inside(branch, fn ->
          Ash.create!(Herd, %{name: "NEW", head: 3, paddock: %{name: "NP", capacity_head: 9}},
            action: :create_with_paddock,
            authorize?: false
          )
        end)

      assert herd.paddock_id

      assert {:ok, _} = Ramal.merge(branch, authorize?: false)
      db = Herd |> Ash.read!(authorize?: false) |> Enum.find(&(&1.name == "NEW"))
      assert Ash.get!(Paddock, db.paddock_id, authorize?: false).name == "NP"
    end

    test "a create inside a branch returns the record and leaves the database alone", %{
      branch: branch
    } do
      herd =
        inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)

      assert %Herd{name: "R10", head: 5, id: id} = herd
      assert id
      assert herd.inserted_at
      assert herd.__meta__.state == :loaded
      assert db_names() == ["R7", "R8", "R9"]
    end

    test "a read inside a branch sees rows created in that branch", %{branch: branch} do
      inside(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        assert names(Ash.read!(Herd, authorize?: false)) == ["R10", "R7", "R8", "R9"]
      end)
    end

    test "the overlay holds the record and the log holds the call", %{branch: branch} do
      herd =
        inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false) end)

      branch = state(branch)
      assert %{{Herd, herd.id} => {:created, herd}} |> Map.keys() == Map.keys(branch.overlay)
      assert {:created, %Herd{name: "R10"}} = branch.overlay[{Herd, herd.id}]
      assert branch.base == %{}

      assert [{:create, Herd, :create, params, nil, opts, %DateTime{}}] = branch.log
      assert params == %{name: "R10", head: 5}
      assert opts == [key: herd.id, tenant: nil, nested?: false]
    end

    test "the actor is kept in the log", %{branch: branch} do
      inside(branch, fn -> Ash.create!(Herd, %{name: "R10", head: 5}, actor: @admin) end)

      assert [{:create, Herd, :create, _params, @admin, _opts, _at}] = state(branch).log
    end

    test "validations still run: an invalid create is refused and leaves the branch empty", %{
      branch: branch
    } do
      assert {:error, %Ash.Error.Invalid{}} =
               inside(branch, fn -> Ash.create(Herd, %{name: "R10"}, authorize?: false) end)

      branch = state(branch)
      assert branch.overlay == %{}
      assert branch.log == []
    end

    test "a primary key the database generates is refused with a message that says what to do",
         %{} do
      {:ok, branch} = Ramal.branch(Ramal.Test.Capture)

      assert {:error, error} = inside(branch, fn -> Ash.create(Ticket, %{title: "t"}) end)
      assert reason_of(error) == :database_generated_key
      assert Exception.message(Ramal.Error.find(error)) =~ "uuid_primary_key"
      assert state(branch).overlay == %{}
    end
  end

  describe "update" do
    test "an update inside a branch returns the new record and leaves the database alone", %{
      branch: branch,
      herds: herds
    } do
      updated = inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)

      assert updated.head == 31
      assert updated.id == herds.r7.id
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 30
    end

    test "an update through a select-only struct stores the whole row and fingerprints it", %{
      branch: branch,
      paddocks: p
    } do
      inside(branch, fn ->
        partial =
          Herd
          |> Ash.Query.select([:id, :name])
          |> Ash.Query.filter(name == "R7")
          |> Ash.read_one!(authorize?: false)

        assert %Ash.NotLoaded{} = partial.head
        Ash.update!(partial, %{name: "R7z"}, authorize?: false)

        assert [row] = Herd |> Ash.Query.filter(name == "R7z") |> Ash.read!(authorize?: false)
        assert {row.head, row.paddock_id} == {30, p.l07.id}
      end)

      assert Enum.map(Map.values(state(branch).base), & &1.fingerprint)
             |> Enum.all?(&is_integer/1)

      assert {:ok, [change]} = Ramal.diff(branch)
      assert %{name: {"R7", "R7z"}} = change.changes
    end

    test "a destroy through a select-only struct stores the whole row and fingerprints it", %{
      branch: branch
    } do
      inside(branch, fn ->
        partial =
          Herd
          |> Ash.Query.select([:id])
          |> Ash.Query.filter(name == "R7")
          |> Ash.read_one!(authorize?: false)

        Ash.destroy!(partial, authorize?: false)
      end)

      assert Enum.map(Map.values(state(branch).base), & &1.fingerprint)
             |> Enum.all?(&is_integer/1)

      assert {:ok, [%{kind: :deleted}]} = Ramal.diff(branch)
    end

    test "two updates through the same struct both land, as two UPDATEs would", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        second = Ash.update!(herds.r7, %{name: "R7x"}, authorize?: false)

        # The data layer returns the row it holds, not the stale struct with one change on it.
        assert {second.name, second.head} == {"R7x", 31}

        r7 = Ash.get!(Herd, herds.r7.id, authorize?: false)
        assert {r7.name, r7.head} == {"R7x", 31}
      end)

      assert {:ok, [change]} = Ramal.diff(branch)
      assert %{head: {30, 31}, name: {"R7", "R7x"}} = change.changes

      assert {:ok, _} = Ramal.merge(branch, authorize?: false)
      db = Ash.get!(Herd, herds.r7.id, authorize?: false)
      assert {db.name, db.head} == {"R7x", 31}
    end

    test "a no-op update through a stale struct keeps an earlier update", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.update!(herds.r7, %{}, authorize?: false)
        assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 31
      end)
    end

    test "a row the branch created can be updated through the struct it was created as", %{
      branch: branch
    } do
      inside(branch, fn ->
        created = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(created, %{head: 6}, authorize?: false)
        Ash.update!(created, %{name: "R10b"}, authorize?: false)

        herd = Ash.get!(Herd, created.id, authorize?: false)
        assert {herd.name, herd.head} == {"R10b", 6}
      end)
    end

    test "a read inside a branch sees the updated row", %{branch: branch, herds: herds} do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 31

        assert [%{head: 31}] =
                 Herd |> Ash.Query.filter(head == 31) |> Ash.read!(authorize?: false)
      end)
    end

    test "the base row as first seen is kept once, even after more updates", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        r7 = Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.update!(r7, %{head: 32}, authorize?: false)
      end)

      branch = state(branch)
      key = {Herd, herds.r7.id}
      assert {:updated, %Herd{head: 32}} = branch.overlay[key]
      assert %{snapshot: %Herd{head: 30}, fingerprint: fingerprint} = branch.base[key]
      assert fingerprint == Ramal.Resource.fingerprint(herds.r7)

      assert [
               {:update, Herd, :update, %{head: 32}, nil, _, _},
               {:update, Herd, :update, %{head: 31}, nil, _, _}
             ] = branch.log
    end

    test "update timestamps move like they would in the database", %{branch: branch, herds: herds} do
      updated = inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)
      assert DateTime.compare(updated.updated_at, herds.r7.updated_at) in [:gt, :eq]
    end

    test "an update that changes nothing is logged, leaves the row as it was and is not in the diff",
         %{
           branch: branch,
           herds: herds
         } do
      inside(branch, fn -> Ash.update!(herds.r7, %{head: 30}, authorize?: false) end)

      assert {:ok, []} = Ramal.diff(branch)
      state = state(branch)
      assert [{:update, Herd, :update, %{head: 30}, nil, _, _}] = state.log
      assert {:updated, %{head: 30}} = state.overlay[{Herd, herds.r7.id}]
    end

    test "updating a row the branch created keeps it created", %{branch: branch} do
      inside(branch, fn ->
        herd = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(herd, %{head: 6}, authorize?: false)
      end)

      branch = state(branch)
      assert [{{Herd, _}, {:created, %Herd{head: 6}}}] = Map.to_list(branch.overlay)
      assert branch.base == %{}
    end
  end

  describe "destroy" do
    test "a destroy inside a branch hides the row and leaves the database alone", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        assert :ok = Ash.destroy!(herds.r9, authorize?: false)
        assert names(Ash.read!(Herd, authorize?: false)) == ["R7", "R8"]
        assert {:error, _} = Ash.get(Herd, herds.r9.id, authorize?: false)
      end)

      assert db_names() == ["R7", "R8", "R9"]
      branch = state(branch)
      assert branch.overlay == %{{Herd, herds.r9.id} => :deleted}
      assert %{snapshot: %Herd{name: "R9"}} = branch.base[{Herd, herds.r9.id}]
    end

    test "destroying a row the branch created leaves no trace in the overlay", %{branch: branch} do
      inside(branch, fn ->
        herd = Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.destroy!(herd, authorize?: false)
      end)

      branch = state(branch)
      assert branch.overlay == %{}

      assert [{:destroy, Herd, :destroy, _, _, _, _}, {:create, Herd, :create, _, _, _, _}] =
               branch.log
    end
  end

  describe "a row the branch already destroyed" do
    test "cannot be updated or destroyed again, as the data layer would refuse", %{
      branch: branch,
      herds: herds
    } do
      inside(branch, fn ->
        Ash.destroy!(herds.r9, authorize?: false)

        assert {:error, error} = Ash.update(herds.r9, %{head: 99}, authorize?: false)
        assert [%Ash.Error.Changes.StaleRecord{resource: Herd}] = error.errors

        assert {:error, error} = Ash.destroy(herds.r9, authorize?: false)
        assert [%Ash.Error.Changes.StaleRecord{resource: Herd}] = error.errors

        assert names(Ash.read!(Herd, authorize?: false)) == ["R7", "R8"]
      end)

      branch = state(branch)
      assert branch.overlay == %{{Herd, herds.r9.id} => :deleted}
      assert length(branch.log) == 1
    end

    test "leaves a branch that still merges", %{branch: branch, herds: herds} do
      inside(branch, fn ->
        Ash.destroy!(herds.r9, authorize?: false)
        {:error, _} = Ash.update(herds.r9, %{head: 99}, authorize?: false)
      end)

      assert {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch, authorize?: false)
      assert db_names() == ["R7", "R8"]
    end
  end

  describe "the actions of the test domain" do
    test "Herd.move validates capacity against moves made earlier in the same branch", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        moved =
          Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)

        assert moved.paddock_id == paddocks.l18.id

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Ash.update(herds.r8, %{to_paddock_id: paddocks.l18.id},
                   action: :move,
                   actor: @admin
                 )

        assert Exception.message(error) =~ "already has 55"
      end)

      assert Ash.get!(Herd, herds.r7.id, authorize?: false).paddock_id == paddocks.l07.id
      assert Move |> Ash.read!(authorize?: false) == []
    end

    test "the move's own after_action hook creates its Move in the branch and marks it nested", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      inside(branch, fn ->
        Ash.update!(herds.r7, %{to_paddock_id: paddocks.l18.id}, action: :move, actor: @admin)

        assert [%Move{herd_id: herd_id, to_paddock_id: to}] = Ash.read!(Move, authorize?: false)
        assert herd_id == herds.r7.id
        assert to == paddocks.l18.id
      end)

      assert [
               {:create, Move, :create, _, _, move_opts, _},
               {:update, Herd, :move, _, @admin, herd_opts, _}
             ] =
               state(branch).log

      assert move_opts[:nested?] == true
      assert herd_opts[:nested?] == false
      assert Move |> Ash.read!(authorize?: false) == []
    end

    test "an unauthorized actor is refused exactly as outside a branch", %{
      branch: branch,
      herds: herds,
      paddocks: paddocks
    } do
      params = %{to_paddock_id: paddocks.l18.id}
      outside = Ash.update(herds.r7, params, action: :move, actor: @member)

      inside =
        inside(branch, fn -> Ash.update(herds.r7, params, action: :move, actor: @member) end)

      assert {:error, %Ash.Error.Forbidden{}} = outside
      assert {:error, %Ash.Error.Forbidden{}} = inside
      assert state(branch).log == []
    end
  end

  describe "bulk actions and upserts" do
    test "a bulk create is refused and writes nothing", %{branch: branch} do
      result =
        inside(branch, fn ->
          Ash.bulk_create([%{name: "R10", head: 1}, %{name: "R11", head: 2}], Herd, :create,
            authorize?: false,
            return_errors?: true,
            return_records?: true
          )
        end)

      assert %Ash.BulkResult{errors: [error | _]} = result
      assert reason_of(error) == :bulk_unsupported
      assert Exception.message(Ramal.Error.find(error)) =~ "once per record"
      assert db_names() == ["R7", "R8", "R9"]
      assert state(branch).overlay == %{}
    end

    test "a bulk destroy is refused and writes nothing", %{branch: branch} do
      result =
        inside(branch, fn ->
          Ash.bulk_destroy(Herd, :destroy, %{},
            authorize?: false,
            return_errors?: true,
            strategy: [:stream]
          )
        end)

      assert %Ash.BulkResult{status: :error} = result
      assert db_names() == ["R7", "R8", "R9"]
      assert state(branch).overlay == %{}
    end

    test "a bulk update is refused and writes nothing", %{branch: branch} do
      result =
        inside(branch, fn ->
          Ash.bulk_update(Herd, :update, %{head: 1}, authorize?: false, return_errors?: true)
        end)

      assert %Ash.BulkResult{status: :error} = result

      assert Herd |> Ash.read!(authorize?: false) |> Enum.map(& &1.head) |> Enum.sort() == [
               25,
               30,
               35
             ]

      assert state(branch).overlay == %{}
    end

    test "an upsert action is refused" do
      {:ok, branch} = Ramal.branch(Ramal.Test.Capture)

      assert {:error, error} =
               inside(branch, fn -> Ash.create(Flaky, %{text: "x"}, action: :upsert) end)

      assert reason_of(error) == :upsert_unsupported
      assert state(branch).overlay == %{}
    end
  end

  describe "a failing action" do
    setup do
      {:ok, branch} = Ramal.branch(Ramal.Test.Capture)
      {:ok, capture_branch: branch}
    end

    test "leaves the branch as it found it when a later hook returns an error", %{
      capture_branch: branch
    } do
      assert {:error, _} =
               inside(branch, fn -> Ash.create(Flaky, %{text: "x"}, action: :create_then_fail) end)

      branch = state(branch)
      assert branch.overlay == %{}
      assert branch.log == []
    end

    test "leaves the branch as it found it when a later hook raises", %{capture_branch: branch} do
      assert_raise Ash.Error.Unknown, fn ->
        inside(branch, fn -> Ash.create(Flaky, %{text: "x"}, action: :create_then_raise) end)
      end

      branch = state(branch)
      assert branch.overlay == %{}
      assert branch.log == []
      assert Process.get(:ramal_capture_frame) == nil
    end

    test "keeps the writes made before it", %{capture_branch: branch} do
      inside(branch, fn ->
        kept = Ash.create!(Flaky, %{text: "kept"})
        assert {:error, _} = Ash.create(Flaky, %{text: "x"}, action: :create_then_fail)
        kept
      end)

      assert [{_, {:created, %Flaky{text: "kept"}}}] = state(branch).overlay |> Map.to_list()
      assert [{:create, Flaky, :create, _, _, _, _}] = state(branch).log
    end
  end

  describe "notifications" do
    setup do
      Process.register(self(), :ramal_test_notifications)
      {:ok, branch} = Ramal.branch(Ramal.Test.Capture)
      {:ok, capture_branch: branch}
    end

    test "are not sent for writes inside a branch", %{capture_branch: branch} do
      inside(branch, fn -> Ash.create!(Silent, %{text: "hello"}) end)
      refute_receive {:notified, _, _}, 50
    end

    test "are sent when the resource opts in, after run/2 returns", %{capture_branch: branch} do
      inside(branch, fn ->
        Ash.create!(Announced, %{text: "hello"})
        refute_received {:notified, _, _}
      end)

      assert_receive {:notified, Announced, :create}
    end

    test "are sent as usual outside a branch" do
      Ash.create!(Silent, %{text: "hello"})
      assert_receive {:notified, Silent, :create}
    end
  end

  describe "telemetry" do
    test "every captured write emits [:ramal, :write, :capture]", %{branch: branch, herds: herds} do
      test = self()
      handler = "capture-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ramal, :write, :capture],
        fn _event, _measurements, metadata, _config -> send(test, {:captured, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      inside(branch, fn -> Ash.update!(herds.r7, %{head: 31}, authorize?: false) end)

      branch_id = branch.id

      assert_receive {:captured,
                      %{
                        branch_id: ^branch_id,
                        domain: Farm,
                        action_type: :update,
                        resource: Herd,
                        action: :update,
                        nested?: false
                      }}
    end
  end

  describe "atomic updates" do
    setup do
      {:ok, counter: Ash.create!(Counter, %{label: "c", n: 5, m: 3})}
    end

    test "an atomic_update expression is applied to the row the branch holds", %{
      branch: branch,
      counter: counter
    } do
      inside(branch, fn ->
        bumped = Ash.update!(counter, %{}, action: :bump)
        assert bumped.n == 6
        assert Ash.get!(Counter, counter.id).n == 6

        # Each expression sees the row as it was before the update, as in SQL.
        both = Ash.update!(bumped, %{}, action: :bump_and_double)
        assert {both.n, both.m} == {7, 6}
      end)

      assert Ash.get!(Counter, counter.id).n == 5
    end

    test "an atomic expression is evaluated against the branch's row, not a stale struct", %{
      branch: branch,
      counter: counter
    } do
      inside(branch, fn ->
        Ash.update!(counter, %{}, action: :bump)
        again = Ash.update!(counter, %{}, action: :bump)
        assert again.n == 7
      end)

      assert {:ok, _} = Ramal.merge(branch, authorize?: false)
      assert Ash.get!(Counter, counter.id).n == 7
    end

    test "the diff and the merge agree with what the branch showed", %{
      branch: branch,
      counter: counter
    } do
      inside(branch, fn -> Ash.update!(counter, %{}, action: :bump_and_double) end)

      assert {:ok, [change]} = Ramal.diff(branch)
      assert %{n: {5, 6}, m: {3, 6}} = change.changes

      assert {:ok, _} = Ramal.merge(branch, authorize?: false)
      reloaded = Ash.get!(Counter, counter.id)
      assert {reloaded.n, reloaded.m} == {6, 6}
    end

    test "an expression that needs the database fails the action and writes nothing", %{
      branch: branch,
      counter: counter
    } do
      error =
        inside(branch, fn ->
          assert {:error, error} = Ash.update(counter, %{}, action: :bump_in_the_database)
          error
        end)

      assert reason_of(error) == :atomic_unsupported
      assert state(branch).overlay == %{}
    end
  end

  describe "the branch is checked when the action runs, not only when the changeset is built" do
    defp overlay_size(branch), do: map_size(state(branch).overlay)

    test "a create changeset built outside run/2 is refused inside it and writes nothing", %{
      branch: branch
    } do
      changeset =
        Ash.Changeset.for_create(Herd, :create, %{name: "OUTSIDE", head: 1}, authorize?: false)

      result = inside(branch, fn -> Ash.create(changeset, authorize?: false) end)

      assert {:error, error} = result
      assert reason_of(error) == :branch_mismatch
      assert db_names() == ["R7", "R8", "R9"]
      assert overlay_size(branch) == 0
    end

    test "an update and a destroy changeset built outside run/2 are refused inside it", %{
      herds: herds,
      branch: branch
    } do
      update = Ash.Changeset.for_update(herds.r7, :update, %{head: 99}, authorize?: false)
      destroy = Ash.Changeset.for_destroy(herds.r8, :destroy, %{}, authorize?: false)

      assert {:error, error} = inside(branch, fn -> Ash.update(update, authorize?: false) end)
      assert reason_of(error) == :branch_mismatch
      assert {:error, error} = inside(branch, fn -> Ash.destroy(destroy, authorize?: false) end)
      assert reason_of(error) == :branch_mismatch

      assert db_names() == ["R7", "R8", "R9"]
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == herds.r7.head
      assert overlay_size(branch) == 0
    end

    test "a changeset built inside run/2 and run after it returns is refused instead of captured",
         %{
           herds: herds,
           branch: branch
         } do
      create =
        inside(branch, fn ->
          Ash.Changeset.for_create(Herd, :create, %{name: "LATER", head: 1}, authorize?: false)
        end)

      update =
        inside(branch, fn ->
          Ash.Changeset.for_update(herds.r7, :update, %{head: 99}, authorize?: false)
        end)

      assert {:error, error} = Ash.create(create, authorize?: false)
      assert reason_of(error) == :branch_mismatch
      assert {:error, error} = Ash.update(update, authorize?: false)
      assert reason_of(error) == :branch_mismatch

      assert db_names() == ["R7", "R8", "R9"]
      assert overlay_size(branch) == 0
    end

    test "a changeset built under one branch and run under another is refused" do
      {:ok, one} = Ramal.branch(Farm)
      {:ok, two} = Ramal.branch(Farm)

      changeset =
        inside(one, fn ->
          Ash.Changeset.for_create(Herd, :create, %{name: "X", head: 1}, authorize?: false)
        end)

      assert {:error, error} = inside(two, fn -> Ash.create(changeset, authorize?: false) end)
      assert reason_of(error) == :branch_mismatch
      assert overlay_size(one) == 0
      assert overlay_size(two) == 0
    end

    test "a changeset that carries the branch in its context still runs outside run/2", %{
      branch: branch
    } do
      Ash.create!(Herd, %{name: "CTX", head: 1},
        authorize?: false,
        context: Ramal.context(branch)
      )

      assert db_names() == ["R7", "R8", "R9"]
      assert overlay_size(branch) == 1
    end

    test "a query prepared inside run/2 and read after it returns is refused", %{branch: branch} do
      query = inside(branch, fn -> Ash.Query.for_read(Herd, :read, %{}, authorize?: false) end)

      assert {:error, error} = Ash.read(query, authorize?: false)
      assert reason_of(error) == :branch_mismatch
    end

    test "a query prepared outside run/2 is patched when it is read inside it", %{branch: branch} do
      outside = Ash.Query.for_read(Herd, :read, %{}, authorize?: false)
      filtered = outside |> Ash.Query.filter(head < 100) |> Ash.Query.sort(name: :desc)

      {plain, patched} =
        inside(branch, fn ->
          Ash.create!(Herd, %{name: "IN", head: 1}, authorize?: false)

          Ash.destroy!(
            Ash.get!(Herd, Ash.read!(Herd, authorize?: false) |> hd() |> Map.fetch!(:id),
              authorize?: false
            ),
            authorize?: false
          )

          {names(Ash.read!(outside)), Enum.map(Ash.read!(filtered), & &1.name)}
        end)

      assert length(plain) == 3
      assert "IN" in plain
      assert "IN" in patched
      assert patched == Enum.sort(patched, :desc)
      assert length(db_names()) == 3
      assert Enum.sort(db_names()) == ["R7", "R8", "R9"]
    end

    test "a query prepared outside run/2 still runs as an atomic bulk update outside a branch", %{
      herds: herds
    } do
      query = Ash.Query.for_read(Herd, :read, %{}, authorize?: false)

      result =
        Ash.bulk_update(query, :update, %{head: 1},
          authorize?: false,
          strategy: :atomic,
          return_errors?: true
        )

      assert %Ash.BulkResult{status: :success} = result
      assert Ash.get!(Herd, herds.r7.id, authorize?: false).head == 1
    end
  end

  describe "tasks started inside run/2" do
    test "Ash.bulk_create with max_concurrency is refused and writes nothing", %{branch: branch} do
      for opts <- [
            [max_concurrency: 2, batch_size: 1],
            [max_concurrency: 2],
            [max_concurrency: 4, batch_size: 2]
          ] do
        result =
          inside(branch, fn ->
            Ash.bulk_create(
              [%{name: "B1", head: 1}, %{name: "B2", head: 1}, %{name: "B3", head: 1}],
              Herd,
              :create,
              [authorize?: false, return_errors?: true, return_records?: true] ++ opts
            )
          end)

        assert result.status == :error

        assert Enum.any?(
                 result.errors,
                 &(Ramal.Error.find(&1) |> Map.get(:reason) == :bulk_unsupported)
               )
      end

      assert db_names() == ["R7", "R8", "R9"]
      assert overlay_size(branch) == 0
    end

    test "a write from a Task is captured in the branch", %{branch: branch} do
      inside(branch, fn ->
        Task.async(fn -> Ash.create!(Herd, %{name: "TASK", head: 1}, authorize?: false) end)
        |> Task.await()
      end)

      assert db_names() == ["R7", "R8", "R9"]
      assert overlay_size(branch) == 1
    end

    test "a write from a Task started by a hook of a captured action is refused", %{
      branch: branch
    } do
      result =
        inside(branch, fn ->
          Herd
          |> Ash.Changeset.for_create(:create, %{name: "OUTER", head: 1}, authorize?: false)
          |> Ash.Changeset.after_action(fn _changeset, herd ->
            # An ETS resource, so the task needs no database connection while the outer action holds the sandbox's.
            case Task.async(fn -> Ash.create(Counter, %{}, authorize?: false) end)
                 |> Task.await() do
              {:ok, _counter} -> {:ok, herd}
              {:error, error} -> {:error, error}
            end
          end)
          |> Ash.create(authorize?: false)
        end)

      assert {:error, error} = result
      assert reason_of(error) == :task_in_action
      assert db_names() == ["R7", "R8", "R9"]
      assert overlay_size(branch) == 0
    end
  end
end
