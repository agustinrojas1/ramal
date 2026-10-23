defmodule Mix.Tasks.Ramal.Gen.MigrationTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ramal.Gen.Migration

  @args ["--repo", "Ramal.TestRepo", "--no-compile", "--no-deps-check"]

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ramal-gen-migration-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    {:ok, dir: Path.join(dir, "migrations")}
  end

  defp create_files(dir, name), do: Path.wildcard(Path.join(dir, "*_#{name}.exs"))

  test "a new install gets the table, the owner column and the write log, in that order, into the given directory",
       %{dir: dir} do
    assert [create, owner, writes] = Migration.run(@args ++ ["--migrations-path", dir])

    assert Path.dirname(create) == dir
    assert Path.basename(create) =~ ~r/^\d{14}_create_ramal_branches\.exs$/
    assert Path.basename(owner) =~ ~r/^\d{14}_add_ramal_branch_owner\.exs$/
    assert Path.basename(writes) =~ ~r/^\d{14}_create_ramal_branch_writes\.exs$/
    assert Path.basename(create) < Path.basename(owner)
    assert Path.basename(owner) < Path.basename(writes)
    body = File.read!(create)
    assert body =~ "defmodule Ramal.TestRepo.Migrations.CreateRamalBranches do"
    assert body =~ "create table(:ramal_branches, primary_key: false)"
    assert body =~ "add :state, :map, null: false"

    assert File.read!(owner) =~
             "GENERATED ALWAYS AS (NULLIF(state -> 'owner', 'null'::jsonb)) STORED"

    body = File.read!(writes)
    assert body =~ "defmodule Ramal.TestRepo.Migrations.CreateRamalBranchWrites do"
    assert body =~ "create table(:ramal_branch_writes, primary_key: false)"
    assert body =~ "on_delete: :delete_all"
  end

  @migration_modules [
    Ramal.TestRepo.Migrations.CreateRamalBranches,
    Ramal.TestRepo.Migrations.AddRamalBranchOwner,
    Ramal.TestRepo.Migrations.CreateRamalBranchWrites
  ]

  defp unload_migrations do
    for module <- @migration_modules do
      :code.purge(module)
      :code.delete(module)
    end
  end

  test "the generated files compile to Ecto migrations", %{dir: dir} do
    files = Migration.run(@args ++ ["--migrations-path", dir])
    # The suite's own migrations ran in this VM, with the same module names.
    unload_migrations()

    modules = for file <- files, {module, _binary} <- Code.compile_file(file), do: module

    assert modules == [
             Ramal.TestRepo.Migrations.CreateRamalBranches,
             Ramal.TestRepo.Migrations.AddRamalBranchOwner,
             Ramal.TestRepo.Migrations.CreateRamalBranchWrites
           ]

    assert function_exported?(Ramal.TestRepo.Migrations.CreateRamalBranches, :change, 0)
    assert function_exported?(Ramal.TestRepo.Migrations.AddRamalBranchOwner, :up, 0)
    assert function_exported?(Ramal.TestRepo.Migrations.AddRamalBranchOwner, :down, 0)
    assert function_exported?(Ramal.TestRepo.Migrations.CreateRamalBranchWrites, :change, 0)
  after
    unload_migrations()
  end

  test "the migrations the test suite runs are what the generator writes", %{dir: dir} do
    [create, owner, writes] = Migration.run(@args ++ ["--migrations-path", dir])
    [installed_create] = Path.wildcard("priv/test_repo/migrations/*_create_ramal_branches.exs")
    [installed_owner] = Path.wildcard("priv/test_repo/migrations/*_add_ramal_branch_owner.exs")

    [installed_writes] =
      Path.wildcard("priv/test_repo/migrations/*_create_ramal_branch_writes.exs")

    assert File.read!(create) == File.read!(installed_create)
    assert File.read!(owner) == File.read!(installed_owner)
    assert File.read!(writes) == File.read!(installed_writes)
  end

  test "a host that installed 0.3.0 gets the owner migration and the write log", %{dir: dir} do
    File.mkdir_p!(dir)
    old = Path.join(dir, "20260101000000_create_ramal_branches.exs")
    File.write!(old, "# written by 0.3.0\n")

    assert [owner, writes] = Migration.run(@args ++ ["--migrations-path", dir])

    assert Path.basename(owner) =~ ~r/^\d{14}_add_ramal_branch_owner\.exs$/
    assert Path.basename(writes) =~ ~r/^\d{14}_create_ramal_branch_writes\.exs$/
    assert File.read!(old) == "# written by 0.3.0\n"
    assert create_files(dir, "create_ramal_branches") == [old]
  end

  test "a host that has the owner column gets only the write log", %{dir: dir} do
    File.mkdir_p!(dir)

    for name <- ["create_ramal_branches", "add_ramal_branch_owner"],
        do: File.write!(Path.join(dir, "20260101000000_#{name}.exs"), "# written earlier\n")

    assert [writes] = Migration.run(@args ++ ["--migrations-path", dir])
    assert Path.basename(writes) =~ ~r/^\d{14}_create_ramal_branch_writes\.exs$/
  end

  test "refuses to write a second copy", %{dir: dir} do
    [_create, _owner, _writes] = Migration.run(@args ++ ["--migrations-path", dir])

    assert_raise Mix.Error, ~r/already exist/, fn ->
      Migration.run(@args ++ ["--migrations-path", dir])
    end

    assert dir |> File.ls!() |> length() == 3
  end
end
