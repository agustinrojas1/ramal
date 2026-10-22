if Code.ensure_loaded?(Mix.EctoSQL) do
  defmodule Mix.Tasks.Ramal.Gen.Migration do
    @shortdoc "Generates the migration for Ramal's branch table"

    @moduledoc """
    Writes a migration that creates the `ramal_branches` table `Ramal.Storage.Postgres` uses.

        $ mix ramal.gen.migration
        $ mix ramal.gen.migration -r MyApp.Repo

    The file goes where `mix ecto.gen.migration` would put it: `priv/<repo>/migrations`, or the directory given with
    `--migrations-path`. Run it once; a second run refuses when the migration already exists.

    ## Options

      * `-r`, `--repo` - the repo to generate the migration for, default: the first of `:ecto_repos`
      * `--migrations-path` - the directory to write into
      * `--no-compile`, `--no-deps-check` - as for the Ecto tasks

    ## Example

        $ mix ramal.gen.migration -r MyApp.Repo
        * creating priv/repo/migrations/20261022120000_create_ramal_branches.exs
    """

    use Mix.Task

    import Mix.Ecto
    import Mix.EctoSQL
    import Mix.Generator

    @switches [
      repo: [:string, :keep],
      no_compile: :boolean,
      no_deps_check: :boolean,
      migrations_path: :string
    ]
    @name "create_ramal_branches"

    @impl true
    def run(args) do
      repos = parse_repo(args)
      {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: [r: :repo])

      Enum.map(repos, fn repo ->
        ensure_repo(repo, args)
        path = opts[:migrations_path] || Path.join(source_repo_priv(repo), "migrations")

        if Path.wildcard(Path.join(path, "*_#{@name}.exs")) != [] do
          Mix.raise("the Ramal migration already exists in #{path}")
        end

        unless File.dir?(path), do: create_directory(path)
        file = Path.join(path, "#{timestamp()}_#{@name}.exs")
        create_file(file, template(repo))
        file
      end)
    end

    defp timestamp do
      {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
      "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
    end

    defp pad(i) when i < 10, do: <<?0, ?0 + i>>
    defp pad(i), do: to_string(i)

    defp template(repo) do
      """
      defmodule #{inspect(repo)}.Migrations.CreateRamalBranches do
        use Ecto.Migration

        # Created by `mix ramal.gen.migration`. `state` holds the overlay, base, log and metadata as Ramal.Storage.Codec
        # writes them.
        def change do
          create table(:ramal_branches, primary_key: false) do
            add :id, :uuid, primary_key: true
            add :domain, :text, null: false
            add :name, :text
            add :status, :text, null: false
            add :state, :map, null: false
            add :inserted_at, :utc_datetime_usec, null: false
            add :updated_at, :utc_datetime_usec, null: false
          end

          create index(:ramal_branches, [:domain, :status])
        end
      end
      """
    end
  end
end
