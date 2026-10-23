if Code.ensure_loaded?(Mix.EctoSQL) do
  defmodule Mix.Tasks.Ramal.Gen.Migration do
    @shortdoc "Generates the migration for Ramal's branch table"

    @moduledoc """
    Writes the migrations for the `ramal_branches` table `Ramal.Storage.Postgres` uses.

        $ mix ramal.gen.migration
        $ mix ramal.gen.migration -r MyApp.Repo

    Three migrations make the table: `create_ramal_branches`; `add_ramal_branch_owner`, which adds the `owner` column
    Postgres generates from `state -> 'owner'` and its index (ADR 0021); and `add_ramal_branch_epoch`, which adds the
    `epoch` column a cluster fences writes with (ADR 0044). A new install gets all three. A host that installed
    0.3.0 or earlier already has the first and gets the other two; it is safe to run on a table that has the columns.
    Adding `owner` rewrites the table once, which is small; adding `epoch` does not rewrite it. The task writes whichever
    of the three are missing and refuses when none is. The epoch is only read with `cluster: true`, so a host that does not
    run a cluster can skip that migration.

    The files go where `mix ecto.gen.migration` would put them: `priv/<repo>/migrations`, or the directory given with
    `--migrations-path`.

    ## Options

      * `-r`, `--repo` - the repo to generate the migration for, default: the first of `:ecto_repos`
      * `--migrations-path` - the directory to write into
      * `--no-compile`, `--no-deps-check` - as for the Ecto tasks

    ## Example

        $ mix ramal.gen.migration -r MyApp.Repo
        * creating priv/repo/migrations/20261022120000_create_ramal_branches.exs
        * creating priv/repo/migrations/20261022120001_add_ramal_branch_owner.exs
        * creating priv/repo/migrations/20261022120002_add_ramal_branch_epoch.exs
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
    @create "create_ramal_branches"
    @owner "add_ramal_branch_owner"
    @epoch "add_ramal_branch_epoch"

    @impl true
    def run(args) do
      repos = parse_repo(args)
      {opts, _rest} = OptionParser.parse!(args, strict: @switches, aliases: [r: :repo])

      Enum.flat_map(repos, fn repo ->
        ensure_repo(repo, args)
        path = opts[:migrations_path] || Path.join(source_repo_priv(repo), "migrations")

        # Each timestamp is one second after the one before, so that a column is added to a table that exists.
        missing =
          [
            {@create, &create_template/1},
            {@owner, &owner_template/1},
            {@epoch, &epoch_template/1}
          ]
          |> Enum.reject(fn {name, _template} ->
            Path.wildcard(Path.join(path, "*_#{name}.exs")) != []
          end)
          |> Enum.with_index()

        if missing == [] do
          Mix.raise("the Ramal migrations already exist in #{path}")
        end

        unless File.dir?(path), do: create_directory(path)

        Enum.map(missing, fn {{name, template}, offset} ->
          file = Path.join(path, "#{timestamp(offset)}_#{name}.exs")
          create_file(file, template.(repo))
          file
        end)
      end)
    end

    defp timestamp(offset) do
      seconds = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) + offset
      {{y, m, d}, {hh, mm, ss}} = :calendar.gregorian_seconds_to_datetime(seconds)
      "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
    end

    defp pad(i) when i < 10, do: <<?0, ?0 + i>>
    defp pad(i), do: to_string(i)

    defp create_template(repo) do
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

    # A constant default is stored in the catalog, not written to every row (Postgres 11), so this does not rewrite the
    # table. bigint, because the epoch counts every load of a branch for as long as the row lives.
    defp epoch_template(repo) do
      """
      defmodule #{inspect(repo)}.Migrations.AddRamalBranchEpoch do
        use Ecto.Migration

        # Created by `mix ramal.gen.migration`. Only a Ramal.Supervisor with `cluster: true` reads it.
        def up do
          execute "ALTER TABLE ramal_branches ADD COLUMN IF NOT EXISTS epoch bigint NOT NULL DEFAULT 0"
        end

        def down do
          execute "ALTER TABLE ramal_branches DROP COLUMN IF EXISTS epoch"
        end
      end
      """
    end

    # `GENERATED ... STORED` needs Postgres 12. A generated column cannot be written, so the storage keeps writing
    # `state` alone and an older node that shares the table during a deploy cannot leave the column out of step. NULLIF
    # maps an unowned branch (JSON null) to SQL NULL. The index is hash, not btree: a btree entry is limited to about
    # 2.7kB, and the owner is any term. It is partial because the lookup for `owner: nil` filters by domain and status
    # instead.
    defp owner_template(repo) do
      """
      defmodule #{inspect(repo)}.Migrations.AddRamalBranchOwner do
        use Ecto.Migration

        # Created by `mix ramal.gen.migration`. Adding a stored generated column rewrites the table once.
        def up do
          execute \"\"\"
          ALTER TABLE ramal_branches ADD COLUMN IF NOT EXISTS owner jsonb
            GENERATED ALWAYS AS (NULLIF(state -> 'owner', 'null'::jsonb)) STORED
          \"\"\"

          execute \"\"\"
          CREATE INDEX IF NOT EXISTS ramal_branches_owner_index ON ramal_branches USING hash (owner)
            WHERE owner IS NOT NULL
          \"\"\"
        end

        def down do
          execute "DROP INDEX IF EXISTS ramal_branches_owner_index"
          execute "ALTER TABLE ramal_branches DROP COLUMN IF EXISTS owner"
        end
      end
      """
    end
  end
end
