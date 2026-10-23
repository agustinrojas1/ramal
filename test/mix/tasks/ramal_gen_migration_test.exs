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

  test "a new install gets the table and the owner column, in that order, into the given directory",
       %{dir: dir} do
    assert [create, owner] = Migration.run(@args ++ ["--migrations-path", dir])

    assert Path.dirname(create) == dir
    assert Path.basename(create) =~ ~r/^\d{14}_create_ramal_branches\.exs$/
    assert Path.basename(owner) =~ ~r/^\d{14}_add_ramal_branch_owner\.exs$/
    assert Path.basename(create) < Path.basename(owner)
    body = File.read!(create)
    assert body =~ "defmodule Ramal.TestRepo.Migrations.CreateRamalBranches do"
    assert body =~ "create table(:ramal_branches, primary_key: false)"
    assert body =~ "add :state, :map, null: false"

    assert File.read!(owner) =~
             "GENERATED ALWAYS AS (NULLIF(state -> 'owner', 'null'::jsonb)) STORED"
  end

  @migration_modules [
    Ramal.TestRepo.Migrations.CreateRamalBranches,
    Ramal.TestRepo.Migrations.AddRamalBranchOwner
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
             Ramal.TestRepo.Migrations.AddRamalBranchOwner
           ]

    assert function_exported?(Ramal.TestRepo.Migrations.CreateRamalBranches, :change, 0)
    assert function_exported?(Ramal.TestRepo.Migrations.AddRamalBranchOwner, :up, 0)
    assert function_exported?(Ramal.TestRepo.Migrations.AddRamalBranchOwner, :down, 0)
  after
    unload_migrations()
  end

  test "the migrations the test suite runs are what the generator writes", %{dir: dir} do
    [create, owner] = Migration.run(@args ++ ["--migrations-path", dir])
    [installed_create] = Path.wildcard("priv/test_repo/migrations/*_create_ramal_branches.exs")
    [installed_owner] = Path.wildcard("priv/test_repo/migrations/*_add_ramal_branch_owner.exs")

    assert File.read!(create) == File.read!(installed_create)
    assert File.read!(owner) == File.read!(installed_owner)
  end

  test "a host that installed 0.3.0 gets only the owner migration", %{dir: dir} do
    File.mkdir_p!(dir)
    old = Path.join(dir, "20260101000000_create_ramal_branches.exs")
    File.write!(old, "# written by 0.3.0\n")

    assert [owner] = Migration.run(@args ++ ["--migrations-path", dir])

    assert Path.basename(owner) =~ ~r/^\d{14}_add_ramal_branch_owner\.exs$/
    assert File.read!(old) == "# written by 0.3.0\n"
    assert create_files(dir, "create_ramal_branches") == [old]
  end

  test "refuses to write a second copy", %{dir: dir} do
    [_create, _owner] = Migration.run(@args ++ ["--migrations-path", dir])

    assert_raise Mix.Error, ~r/already exist/, fn ->
      Migration.run(@args ++ ["--migrations-path", dir])
    end

    assert dir |> File.ls!() |> length() == 2
  end
end
