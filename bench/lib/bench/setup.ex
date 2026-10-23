defmodule Bench.Setup do
  @moduledoc false
  # Creates the database and the two tables the benchmark uses, and seeds `bench_items`.
  #
  # `bench_items` is the base. `bench_deltas` is the relational baseline's per-state overlay (see Bench.Baseline.Delta).
  # `ramal_branches` and `ramal_branch_writes` are Ramal's own storage tables, for the cases that store branches in
  # Postgres.

  alias Ecto.Adapters.SQL

  @spec run(pos_integer, pos_integer) :: %{ids: [String.t()], buckets: pos_integer}
  def run(rows, buckets) do
    config = Bench.Repo.config()
    _ = Bench.Repo.__adapter__().storage_up(config)

    {:ok, _} = Bench.Repo.start_link()

    for sql <- [
          "DROP TABLE IF EXISTS ramal_branch_writes",
          "DROP TABLE IF EXISTS ramal_branches",
          "DROP TABLE IF EXISTS bench_deltas",
          "DROP TABLE IF EXISTS bench_items",
          "DROP TABLE IF EXISTS bench_notes",
          """
          CREATE TABLE bench_items (
            id uuid PRIMARY KEY,
            name text NOT NULL,
            score integer NOT NULL,
            bucket integer NOT NULL
          )
          """,
          "CREATE INDEX bench_items_bucket ON bench_items (bucket)",
          "CREATE TABLE bench_notes (id uuid PRIMARY KEY, body text NOT NULL)",
          "INSERT INTO bench_notes (id, body) SELECT gen_random_uuid(), 'note-' || i FROM generate_series(1, 20) AS i",
          """
          CREATE TABLE bench_deltas (
            state integer NOT NULL,
            id uuid NOT NULL,
            name text NOT NULL,
            score integer NOT NULL,
            bucket integer NOT NULL,
            deleted boolean NOT NULL DEFAULT false,
            PRIMARY KEY (state, id)
          )
          """,
          "CREATE INDEX bench_deltas_bucket ON bench_deltas (state, bucket)",
          # What `mix ramal.gen.migration` makes, without the owner column, for the `durable` case.
          """
          CREATE TABLE ramal_branches (
            id uuid PRIMARY KEY,
            domain text NOT NULL,
            name text,
            status text NOT NULL,
            state jsonb NOT NULL,
            inserted_at timestamp NOT NULL,
            updated_at timestamp NOT NULL
          )
          """,
          """
          CREATE TABLE ramal_branch_writes (
            branch_id uuid NOT NULL REFERENCES ramal_branches (id) ON DELETE CASCADE,
            seq bigint NOT NULL,
            delta jsonb NOT NULL,
            PRIMARY KEY (branch_id, seq)
          )
          """
        ] do
      SQL.query!(Bench.Repo, sql, [])
    end

    SQL.query!(
      Bench.Repo,
      """
      INSERT INTO bench_items (id, name, score, bucket)
      SELECT gen_random_uuid(), 'item-' || i, (i * 7919) % 1000, i % $1
      FROM generate_series(1, $2) AS i
      """,
      [buckets, rows]
    )

    SQL.query!(Bench.Repo, "ANALYZE bench_items", [])

    %{rows: rows} = SQL.query!(Bench.Repo, "SELECT id FROM bench_items ORDER BY name", [])
    %{ids: Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end), buckets: buckets}
  end

  @spec postgres_version() :: String.t()
  def postgres_version do
    %{rows: [[version]]} = SQL.query!(Bench.Repo, "SELECT version()", [])
    version
  end
end
