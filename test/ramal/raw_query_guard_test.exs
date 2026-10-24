defmodule Ramal.RawQueryGuardTest do
  # Ramal.Supervisor is one per node and named, and the guard's handler is attached to the one repo, so these tests
  # cannot run concurrently.
  use Ramal.DataCase, async: false

  import Ecto.Query, only: [from: 2]

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

    test "a raw query on a branched table inside a branch emits the event, for every query" do
      assert {:ok, _} = in_branch(fn -> for _ <- 1..3, do: raw_read() end)

      for _ <- 1..3, do: assert_received({:detected, %{table: "paddocks"}})
      refute_received {:detected, _}
    end

    test "the event names the branch, the resource, the query, the call site and the stack" do
      assert {:ok, _} = in_branch(&raw_read/0)

      assert_received {:detected, meta}
      assert is_binary(meta.branch_id)
      assert meta.resource == Paddock
      assert meta.repo == TestRepo
      assert meta.query =~ ~s(FROM "paddocks")
      assert meta.call_site =~ "Ramal.RawQueryGuardTest.raw_read/0"
      assert [{Ramal.RawQueryGuardTest, :raw_read, 0, _} | _] = meta.stacktrace
      assert Exception.format_stacktrace(meta.stacktrace) =~ "raw_read"
    end

    test "the same query outside a branch emits nothing" do
      raw_read()
      refute_received {:detected, _}
    end

    test "a query on a table no branched resource uses is not reported" do
      assert {:ok, _} = in_branch(fn -> SQL.query!(TestRepo, "SELECT 1") end)

      refute_received {:detected, _}
    end

    test "raw SQL that joins a branched table is reported" do
      sql = ~s(SELECT 1 FROM "pg_tables" t JOIN "paddocks" p ON p.name = t.tablename)

      assert {:ok, _} = in_branch(fn -> SQL.query!(TestRepo, sql) end)

      assert_received {:detected, %{table: "paddocks"}}
    end

    test "hand-written SQL is reported whether or not it quotes the table" do
      for sql <- [
            "select count(*) from paddocks",
            "SELECT 1 FROM public.paddocks",
            "UPDATE paddocks SET name = name WHERE false",
            "SELECT 1 FROM pg_tables t, paddocks p WHERE false",
            "WITH p AS (SELECT id FROM paddocks) SELECT * FROM p"
          ] do
        assert {:ok, _} = in_branch(fn -> SQL.query!(TestRepo, sql) end)
        assert_received {:detected, %{table: "paddocks"}}
      end
    end

    test "a raw write is reported too" do
      assert {:ok, _} =
               in_branch(fn ->
                 TestRepo.update_all(from(p in "paddocks", where: false), set: [name: "x"])
               end)

      assert_received {:detected, %{table: "paddocks"}}
    end

    test "Ash reads, writes, loads and aggregates inside a branch are not reported" do
      Ash.create!(Paddock, %{name: "base", capacity_head: 3}, authorize?: false)

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

      refute_received {:detected, _}
    end

    test "the merge replays a branch's writes without being reported" do
      branch = branch!()

      {:ok, _} =
        Ramal.run(branch, fn ->
          Ash.create!(Paddock, %{name: "merged", capacity_head: 1}, authorize?: false)
        end)

      assert {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch, authorize?: false)

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

      assert {:ok, _} = in_branch(&raw_read/0)
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

      assert {:ok, _} = in_branch(&raw_read/0)
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

    test "sees a table whose name is not quoted, in any case, and one after a comma in a FROM list" do
      for sql <- [
            "SELECT 1 FROM paddocks",
            "select * from paddocks where name = $1",
            "SELECT 1 FROM public.paddocks p",
            ~s(SELECT 1 FROM "public".paddocks p),
            "update paddocks set name = $1",
            "UPDATE ONLY paddocks SET name = $1",
            "INSERT INTO PADDOCKS (name) VALUES ($1)",
            "SELECT 1 FROM herds h, paddocks p WHERE h.paddock_id = p.id",
            ~s(SELECT 1 FROM herds h, "public"."paddocks" p),
            "SELECT 1 FROM herds h, other o, paddocks p",
            "WITH old AS (SELECT id FROM paddocks) SELECT * FROM old",
            "SELECT 1 FROM herds h JOIN paddocks p ON true"
          ] do
        assert RawQueryGuard.sql_names_table?(sql, "paddocks"), sql
      end
    end

    test "ignores a name that is only part of another one, or a column after a comma" do
      for sql <- [
            "SELECT 1 FROM paddocks_archive",
            "SELECT 1 FROM old_paddocks",
            "SELECT 1 FROM herds h WHERE h.name = 'paddocks'",
            "SELECT name, paddocks FROM herds",
            "SELECT 1 FROM herds h, other WHERE other.paddocks = 1",
            ~s(SELECT 1 FROM "paddocks_archive")
          ] do
        refute RawQueryGuard.sql_names_table?(sql, "paddocks"), sql
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
