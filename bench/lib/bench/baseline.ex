defmodule Bench.Baseline do
  @moduledoc false
  # The comparison systems: what the same job costs on plain Postgres with no Ramal. Both run the same SQL on the same
  # server as the Ramal side.

  defmodule Copy do
    @moduledoc false
    # One scratch table per state, filled by copying the parent. This is the behaviour of a database that branches by
    # copying: every fork is O(rows). The copy is indexed on `bucket`, as the base table is, because a read of a state
    # without the index would not be a fair read.

    alias Ecto.Adapters.SQL

    @counter :bench_copy_counter

    def init, do: :persistent_term.put(@counter, :counters.new(1, []))

    @spec fork(String.t()) :: String.t()
    def fork(parent) do
      counter = :persistent_term.get(@counter)
      :counters.add(counter, 1, 1)
      table = "bench_copy_#{:counters.get(counter, 1)}"

      SQL.query!(
        Bench.Repo,
        "CREATE UNLOGGED TABLE #{table} AS SELECT id, name, score, bucket FROM #{parent}",
        []
      )

      SQL.query!(Bench.Repo, "ALTER TABLE #{table} ADD PRIMARY KEY (id)", [])
      SQL.query!(Bench.Repo, "CREATE INDEX #{table}_bucket ON #{table} (bucket)", [])
      table
    end

    def update(table, id, score) do
      SQL.query!(Bench.Repo, "UPDATE #{table} SET score = $1 WHERE id = $2", [
        score,
        Ecto.UUID.dump!(id)
      ])
    end

    def read(table, bucket_bound) do
      SQL.query!(Bench.Repo, "SELECT id, name, score, bucket FROM #{table} WHERE bucket < $1", [
        bucket_bound
      ]).rows
    end

    def sum(table) do
      %{rows: [[sum]]} =
        SQL.query!(Bench.Repo, "SELECT coalesce(sum(score), 0)::bigint FROM #{table}", [])

      sum
    end

    def discard(table), do: SQL.query!(Bench.Repo, "DROP TABLE #{table}", [])
  end

  defmodule Delta do
    @moduledoc false
    # One shared delta table keyed by (state, id): the relational version of Ramal's overlay. A fork copies the parent's
    # delta rows, a write upserts one, a read is the base minus the state's rows plus the state's rows. It has no
    # validations, no policies and no hooks, which is why it is also the lower bound for what Ramal could cost.

    alias Ecto.Adapters.SQL

    @counter :bench_delta_counter

    def init, do: :persistent_term.put(@counter, :counters.new(1, []))

    @spec new_state() :: integer
    def new_state do
      counter = :persistent_term.get(@counter)
      :counters.add(counter, 1, 1)
      :counters.get(counter, 1)
    end

    def fork(parent) do
      state = new_state()

      SQL.query!(
        Bench.Repo,
        """
        INSERT INTO bench_deltas (state, id, name, score, bucket, deleted)
        SELECT $1, id, name, score, bucket, deleted FROM bench_deltas WHERE state = $2
        """,
        [state, parent]
      )

      state
    end

    def update(state, id, score) do
      SQL.query!(
        Bench.Repo,
        """
        INSERT INTO bench_deltas (state, id, name, score, bucket)
        SELECT $1, i.id, i.name, $3, i.bucket FROM bench_items i WHERE i.id = $2
        ON CONFLICT (state, id) DO UPDATE SET score = EXCLUDED.score
        """,
        [state, Ecto.UUID.dump!(id), score]
      )
    end

    @visible """
    SELECT i.id, i.name, i.score, i.bucket FROM bench_items i
    WHERE NOT EXISTS (SELECT 1 FROM bench_deltas d WHERE d.state = $1 AND d.id = i.id)
    UNION ALL
    SELECT d.id, d.name, d.score, d.bucket FROM bench_deltas d WHERE d.state = $1 AND NOT d.deleted
    """

    def read(state, bucket_bound) do
      SQL.query!(
        Bench.Repo,
        "SELECT id, name, score, bucket FROM (#{@visible}) v WHERE v.bucket < $2",
        [state, bucket_bound]
      ).rows
    end

    def sum(state) do
      %{rows: [[sum]]} =
        SQL.query!(Bench.Repo, "SELECT coalesce(sum(score), 0)::bigint FROM (#{@visible}) v", [
          state
        ])

      sum
    end

    # Applies the state's rows to the base in one statement, the set-based merge a database branching system has.
    def merge(state) do
      SQL.query!(
        Bench.Repo,
        """
        UPDATE bench_items i SET score = d.score
        FROM bench_deltas d WHERE d.state = $1 AND d.id = i.id AND NOT d.deleted
        """,
        [state]
      )

      discard(state)
    end

    def discard(state),
      do: SQL.query!(Bench.Repo, "DELETE FROM bench_deltas WHERE state = $1", [state])
  end
end
