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

  test "writes a timestamped migration for the repo into the given directory", %{dir: dir} do
    assert [file] = Migration.run(@args ++ ["--migrations-path", dir])

    assert Path.dirname(file) == dir
    assert Path.basename(file) =~ ~r/^\d{14}_create_ramal_branches\.exs$/
    body = File.read!(file)
    assert body =~ "defmodule Ramal.TestRepo.Migrations.CreateRamalBranches do"
    assert body =~ "create table(:ramal_branches, primary_key: false)"
    assert body =~ "add :state, :map, null: false"
  end

  test "the generated file compiles to an Ecto migration", %{dir: dir} do
    [file] = Migration.run(@args ++ ["--migrations-path", dir])

    assert [{module, _binary}] = Code.compile_file(file)
    assert module == Ramal.TestRepo.Migrations.CreateRamalBranches
    assert function_exported?(module, :change, 0)
  after
    :code.purge(Ramal.TestRepo.Migrations.CreateRamalBranches)
    :code.delete(Ramal.TestRepo.Migrations.CreateRamalBranches)
  end

  test "the migration the test suite runs is what the generator writes", %{dir: dir} do
    [file] = Migration.run(@args ++ ["--migrations-path", dir])
    [installed] = Path.wildcard("priv/test_repo/migrations/*_create_ramal_branches.exs")

    assert File.read!(file) == File.read!(installed)
  end

  test "refuses to write a second copy", %{dir: dir} do
    [_file] = Migration.run(@args ++ ["--migrations-path", dir])

    assert_raise Mix.Error, ~r/already exists/, fn ->
      Migration.run(@args ++ ["--migrations-path", dir])
    end

    assert dir |> File.ls!() |> length() == 1
  end
end
