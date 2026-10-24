defmodule Ramal.RawQueryGuardTest do
  # Ramal.Supervisor is one per node and named, and the guard's handler is attached to the one repo, so these tests
  # cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Ramal.Error
  alias Ramal.RawQueryGuard
  alias Ramal.Test.Farm.{Herd, Paddock}

  doctest Ramal.RawQueryGuard

  @event [:ramal, :raw_query, :detected]

  setup do
    on_exit(fn -> RawQueryGuard.detach(TestRepo) end)
    :ok
  end

  defp start(mode),
    do: start_supervised!({Ramal.Supervisor, warn_raw_queries: mode, repo: TestRepo})

  defp listen do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      @event,
      fn _event, _measurements, meta, _ -> send(test, {:detected, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # The call site the warning must name. The sort keeps the call from being a tail call, whose frame the VM drops.
  def raw_read, do: Enum.sort(TestRepo.all(from(p in "paddocks", select: p.name)))

  defp branch! do
    {:ok, branch} = Ramal.branch(Farm)
    branch
  end

  defp in_branch(fun), do: Ramal.run(branch!(), fun)

  describe "warn_raw_queries: true" do
    setup do
      start(true)
      listen()
    end

    test "a raw query on a branched table inside a branch warns once with the call site" do
      log =
        capture_log(fn ->
          assert {:ok, _} = in_branch(fn -> for _ <- 1..3, do: raw_read() end)
        end)

      assert log =~ "raw Ecto query on \"paddocks\" (Ramal.Test.Farm.Paddock)"
      assert log =~ "Ramal.RawQueryGuardTest.raw_read/0"
      assert length(String.split(log, "raw Ecto query on")) == 2

      # The event fires for every query, the log only once per call site.
      for _ <- 1..3, do: assert_received({:detected, %{table: "paddocks"}})
    end

    test "the event names the branch, the resource, the query and the call site" do
      capture_log(fn -> assert {:ok, _} = in_branch(&raw_read/0) end)

      assert_received {:detected, meta}
      assert is_binary(meta.branch_id)
      assert meta.resource == Paddock
      assert meta.repo == TestRepo
      assert meta.query =~ ~s(FROM "paddocks")
      assert meta.call_site =~ "raw_read"
    end

    test "the same query outside a branch logs and emits nothing" do
      assert capture_log(&raw_read/0) == ""
      refute_received {:detected, _}
    end

    test "a query on a table no branched resource uses is not reported" do
      log =
        capture_log(fn ->
          assert {:ok, _} = in_branch(fn -> SQL.query!(TestRepo, "SELECT 1") end)
        end)

      assert log == ""
      refute_received {:detected, _}
    end

    test "raw SQL that joins a branched table is reported" do
      sql = ~s(SELECT 1 FROM "pg_tables" t JOIN "paddocks" p ON p.name = t.tablename)

      log =
        capture_log(fn ->
          assert {:ok, _} = in_branch(fn -> SQL.query!(TestRepo, sql) end)
        end)

      assert log =~ "raw Ecto query on"
      assert_received {:detected, %{table: "paddocks"}}
    end

    test "a raw write is reported too" do
      capture_log(fn ->
        assert {:ok, _} =
                 in_branch(fn ->
                   TestRepo.update_all(from(p in "paddocks", where: false), set: [name: "x"])
                 end)
      end)

      assert_received {:detected, %{table: "paddocks"}}
    end

    test "Ash reads, writes, loads and aggregates inside a branch are not reported" do
      Ash.create!(Paddock, %{name: "base", capacity_head: 3}, authorize?: false)

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   in_branch(fn ->
                     paddock =
                       Ash.create!(Paddock, %{name: "new", capacity_head: 2}, authorize?: false)

                     Ash.create!(Herd, %{name: "h", head: 1, paddock_id: paddock.id},
                       authorize?: false
                     )

                     Ash.update!(paddock, %{capacity_head: 5}, authorize?: false)
                     Ash.read!(Paddock, load: [:herds], authorize?: false)
                     Ash.count!(Paddock, authorize?: false)
                     Ramal.aggregate!(Herd, :sum, :head)
                     Ash.destroy!(paddock, authorize?: false)
                   end)
        end)

      assert log == ""
      refute_received {:detected, _}
    end

    test "the merge replays a branch's writes without being reported" do
      branch = branch!()

      {:ok, _} =
        Ramal.run(branch, fn ->
          Ash.create!(Paddock, %{name: "merged", capacity_head: 1}, authorize?: false)
        end)

      log =
        capture_log(fn ->
          assert {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch, authorize?: false)
        end)

      assert log == ""
      refute_received {:detected, _}
    end
  end

  describe "warn_raw_queries: :raise" do
    setup do
      start(:raise)
      listen()
    end

    test "run/2 returns :raw_query after the function returns, with the first query" do
      assert {:error, %Error{reason: :raw_query, details: details}} = in_branch(&raw_read/0)

      assert details.table == "paddocks"
      assert details.resource == Paddock
      assert details.call_site =~ "raw_read"
    end

    test "run!/2 raises it" do
      assert_raise Error, ~r/raw Ecto query on "paddocks"/, fn ->
        Ramal.run!(branch!(), &raw_read/0)
      end
    end

    test "the next run of the branch is not refused" do
      branch = branch!()

      assert {:error, %Error{reason: :raw_query}} = Ramal.run(branch, &raw_read/0)
      assert {:ok, :fine} = Ramal.run(branch, fn -> :fine end)
    end

    test "a run with no raw query, and a raw query outside a branch, return as before" do
      assert {:ok, :ok} = in_branch(fn -> Ash.read!(Paddock, authorize?: false) && :ok end)
      assert is_list(raw_read())
    end
  end

  describe "the option" do
    test "is off by default: nothing is attached and nothing is reported" do
      start_supervised!({Ramal.Supervisor, repo: TestRepo})
      listen()

      assert capture_log(fn -> assert {:ok, _} = in_branch(&raw_read/0) end) == ""
      refute_received {:detected, _}
    end

    test "needs the repo to attach to" do
      assert {:error, {{%ArgumentError{message: message}, _}, _}} =
               start_supervised({Ramal.Supervisor, warn_raw_queries: true})

      assert message =~ "needs `repo: MyApp.Repo`"
    end

    test "takes true, :raise or false" do
      assert_raise ArgumentError, ~r/warn_raw_queries/, fn ->
        Ramal.Supervisor.build_config(warn_raw_queries: :loud)
      end

      assert Ramal.Supervisor.build_config(warn_raw_queries: :raise).raw_queries == :raise
      assert Ramal.Supervisor.build_config([]).raw_queries == false
    end

    test "a supervisor started without it detaches the handler an earlier start left" do
      start(true)
      stop_supervised!(Ramal.Supervisor)
      start_supervised!({Ramal.Supervisor, repo: TestRepo})
      listen()

      assert capture_log(fn -> assert {:ok, _} = in_branch(&raw_read/0) end) == ""
      refute_received {:detected, _}
    end
  end

  describe "event/1" do
    test "comes from the repo's telemetry prefix" do
      assert RawQueryGuard.event(TestRepo) == [:ramal, :test_repo, :query]
    end
  end

  describe "sql_names_table?/2" do
    test "sees a table in FROM, JOIN, UPDATE and INTO, with or without a schema" do
      for sql <- [
            ~s(SELECT 1 FROM "paddocks" AS p0),
            ~s(SELECT 1 FROM "public"."paddocks" AS p0),
            ~s(SELECT 1 FROM "herds" AS h0 INNER JOIN "paddocks" AS p1 ON true),
            ~s(UPDATE "paddocks" AS p0 SET "name" = $1),
            ~s[INSERT INTO "paddocks" ("name") VALUES ($1)],
            ~s(DELETE FROM "paddocks" AS p0)
          ] do
        assert RawQueryGuard.sql_names_table?(sql, "paddocks"), sql
      end
    end

    test "ignores a column or a table with a longer name" do
      refute RawQueryGuard.sql_names_table?(~s(SELECT "paddocks" FROM "herds"), "paddocks")
      refute RawQueryGuard.sql_names_table?(~s(SELECT 1 FROM "paddocks_archive"), "paddocks")
    end
  end

  describe "tripwire" do
    test "assumption: a query AshPostgres runs has an AshPostgres.DataLayer frame in its caller's stack" do
      test = self()
      id = {__MODULE__, :stack}

      :telemetry.attach(
        id,
        RawQueryGuard.event(TestRepo),
        fn _event, _measurements, %{source: source}, _ ->
          {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
          send(test, {:stack, source, Ramal.Ash.data_layer_stack?(stack)})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      Ash.create!(Paddock, %{name: "a", capacity_head: 1}, authorize?: false)
      assert_received {:stack, "paddocks", true}
      Ash.read!(Paddock, authorize?: false)
      assert_received {:stack, "paddocks", true}
      Ash.count!(Paddock, authorize?: false)
      assert_received {:stack, "paddocks", true}

      raw_read()
      assert_received {:stack, "paddocks", false}
    end
  end
end
