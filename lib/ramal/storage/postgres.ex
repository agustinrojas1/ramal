if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Ramal.Storage.Postgres do
    @moduledoc """
    Keeps branches in the `ramal_branches` table of the host's Postgres, so they survive a restart.

    Add the table with `mix ramal.gen.migration`, give the supervisor the repo, and nothing else changes:

        {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}

    One row per branch: `id` (uuid), `domain`, `name`, `status`, `inserted_at` and `updated_at` as columns, and the rest
    in `state` (jsonb) as `Ramal.Storage.Codec` writes it. Branch ids are UUIDs, as `Ramal.Branch.new/2` makes them.
    `owner` (jsonb) is a column Postgres generates from `state -> 'owner'` (ADR 0021), with an index, for the `owner:`
    filter of `Ramal.list/2`; nothing writes it, and it is `NULL` for an unowned branch. A table made by 0.3.0 or
    earlier gets it from the second migration `mix ramal.gen.migration` writes; until then everything but the `owner:`
    filter works.
    `epoch` (bigint, default 0) is the fencing token of a cluster (ADR 0044): `claim/2` increments it, and `put/2` and
    `mark_merged/2` of a branch that carries an epoch write only while the row still has it. Nothing reads it
    without `cluster: true`, so a table without the column works as before; `mix ramal.gen.migration` adds it.
    The write log of a durable branch (ADR 0048) is in `ramal_branch_writes`: one row per action that ended, with the
    branch's `id`, the `seq` of the delta and the delta (jsonb) as `Ramal.Storage.Codec.encode_delta/1` writes it. The
    last migration `mix ramal.gen.migration` writes creates it, with the branch id as a foreign key that cascades, so
    deleting a branch deletes its log. Without the table everything but `durable: true` works.
    The branch process calls this module from its own process, so the repo's pool serves it like any other
    caller. The module exists only when Ecto SQL is a dependency of the host.

    ## Example

        iex> Ramal.Storage.Postgres.table()
        "ramal_branches"
    """

    @behaviour Ramal.Storage

    alias Ecto.Adapters.SQL
    alias Ramal.{Branch, Error}
    alias Ramal.Storage.Codec

    @table "ramal_branches"
    @writes "ramal_branch_writes"
    @columns "id, domain, name, status, state"

    @doc """
    The name of the table `mix ramal.gen.migration` creates.

    ## Example

        iex> Ramal.Storage.Postgres.table()
        "ramal_branches"
    """
    @spec table() :: String.t()
    def table, do: @table

    # A merged row is only ever replaced by a merged branch (an approval adding its decision). A process that missed
    # the merge, because the process that ran it died while the commit was in flight, would otherwise store the branch
    # as open again when it unloads (ADR 0035).
    @upsert """
    INSERT INTO #{@table} (id, domain, name, status, state, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $6)
    ON CONFLICT (id) DO UPDATE SET
      domain = EXCLUDED.domain, name = EXCLUDED.name, status = EXCLUDED.status,
      state = EXCLUDED.state, updated_at = now() AT TIME ZONE 'utc'
    WHERE #{@table}.status <> 'merged' OR EXCLUDED.status = 'merged'
    """

    # The write of a process that holds an epoch. The row must exist, because the process claimed it, and carry that
    # epoch. The WHERE keeps a merged row merged exactly as @upsert does.
    @fenced_put """
    UPDATE #{@table} SET domain = $2, name = $3, status = $4, state = $5, updated_at = now() AT TIME ZONE 'utc'
    WHERE id = $1 AND epoch = $6 AND (status <> 'merged' OR $4 = 'merged')
    RETURNING id
    """

    @impl true
    def put(%Branch{epoch: epoch} = branch, config) when is_integer(epoch) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, state} <- Codec.encode_state(branch),
           {:ok, result} <-
             query(repo, @fenced_put, [
               id,
               Atom.to_string(branch.domain),
               branch.name,
               Atom.to_string(branch.status),
               state,
               epoch
             ]) do
        case result.num_rows do
          1 -> drop_covered(repo, id, branch)
          # No row updated: another process holds the branch now, the row is gone, or it is merged and this write is
          # not. Only the first two are a refusal; the third is the merged guard, which leaves the row as it is.
          0 -> fenced_or_guarded(repo, id, branch, epoch)
        end
      end
    end

    def put(%Branch{} = branch, config) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, state} <- Codec.encode_state(branch),
           {:ok, _result} <-
             query(repo, @upsert, [
               id,
               Atom.to_string(branch.domain),
               branch.name,
               Atom.to_string(branch.status),
               state,
               DateTime.to_naive(branch.inserted_at)
             ]) do
        drop_covered(repo, id, branch)
      end
    end

    # The snapshot is written first and the deltas it covers deleted after it, so a failure between the two leaves
    # deltas that `writes_after/2` ignores (`seq <= wal`) and the next snapshot deletes. Nothing is read or deleted for
    # a branch that is not durable, or has not appended yet, so they need not have the table.
    defp drop_covered(repo, id, %Branch{durable: true, wal: wal}) when wal > 0 do
      with {:ok, _result} <-
             query(repo, "DELETE FROM #{@writes} WHERE branch_id = $1 AND seq <= $2", [id, wal]) do
        :ok
      end
    end

    defp drop_covered(_repo, _id, _branch), do: :ok

    # The delta of a process that holds an epoch is stored only while the row still has it. The row is locked FOR SHARE
    # by the same statement, so a `claim/2` (an UPDATE of the row) waits for the insert, and the process that claims
    # next reads a log with every delta this one was told was stored; and an insert that finds the claim done sees the
    # new epoch (READ COMMITTED re-evaluates the WHERE on the updated row) and stores nothing.
    @fenced_append """
    INSERT INTO #{@writes} (branch_id, seq, delta)
    SELECT id, $2, $3 FROM #{@table} WHERE id = $1 AND epoch = $4 FOR SHARE
    """

    @impl true
    def append(%Branch{epoch: epoch} = branch, seq, delta, config) when is_integer(epoch) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, encoded} <- Codec.encode_delta(delta),
           {:ok, result} <- query(repo, @fenced_append, [id, seq, encoded, epoch]) do
        case result.num_rows do
          1 -> :ok
          0 -> refused_append(repo, id, branch, epoch)
        end
      end
    end

    def append(%Branch{} = branch, seq, delta, config) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, encoded} <- Codec.encode_delta(delta),
           {:ok, _result} <-
             query(repo, "INSERT INTO #{@writes} (branch_id, seq, delta) VALUES ($1, $2, $3)", [
               id,
               seq,
               encoded
             ]) do
        :ok
      end
    end

    # One statement, so the epoch and the log are read together: a branch that another process claimed since has no log
    # to give this one.
    @fenced_writes_after """
    SELECT b.epoch, w.seq, w.delta FROM #{@table} b
    LEFT JOIN #{@writes} w ON w.branch_id = b.id AND w.seq > $2
    WHERE b.id = $1 ORDER BY w.seq
    """

    @impl true
    def writes_after(%Branch{epoch: epoch} = branch, config) when is_integer(epoch) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, result} <- query(repo, @fenced_writes_after, [id, branch.wal]) do
        held_writes(branch, epoch, result.rows)
      end
    end

    def writes_after(%Branch{} = branch, config) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, result} <-
             query(
               repo,
               "SELECT seq, delta FROM #{@writes} WHERE branch_id = $1 AND seq > $2 ORDER BY seq",
               [id, branch.wal]
             ) do
        result.rows |> Enum.map(&decode_write(branch.id, &1)) |> collect()
      end
    end

    defp held_writes(branch, epoch, [[epoch | _] | _] = rows) do
      rows
      |> Enum.reject(fn [_epoch, seq, _delta] -> is_nil(seq) end)
      |> Enum.map(fn [_epoch, seq, stored] -> decode_write(branch.id, [seq, stored]) end)
      |> collect()
    end

    defp held_writes(_branch, _epoch, []), do: {:ok, []}

    defp held_writes(branch, epoch, _other_epoch),
      do: {:error, Ramal.Storage.fenced(branch.id, epoch)}

    defp decode_write(id, [seq, stored]) do
      with {:ok, delta} <- Codec.decode_delta(id, stored), do: {:ok, {seq, delta}}
    end

    # The WHERE of DO UPDATE leaves a row that is already merged as it is and returns nothing for it: the check and the
    # write are one statement, under the row lock the conflict takes.
    @mark_merged """
    INSERT INTO #{@table} (id, domain, name, status, state, inserted_at, updated_at)
    VALUES ($1, $2, $3, 'merged', $4, $5, $5)
    ON CONFLICT (id) DO UPDATE SET
      domain = EXCLUDED.domain, name = EXCLUDED.name, status = EXCLUDED.status,
      state = EXCLUDED.state, updated_at = now() AT TIME ZONE 'utc'
    WHERE #{@table}.status <> 'merged'
    RETURNING id
    """

    @fenced_mark_merged """
    UPDATE #{@table} SET status = 'merged', state = $2, updated_at = now() AT TIME ZONE 'utc'
    WHERE id = $1 AND epoch = $3 AND status <> 'merged'
    RETURNING id
    """

    # Run inside the merge's transaction on the same repo, the row rolls back with a failed merge and commits with a
    # successful one (ADR 0035).
    @impl true
    def mark_merged(%Branch{epoch: epoch} = branch, config) when is_integer(epoch) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, state} <- Codec.encode_state(%{branch | status: :merged}),
           {:ok, result} <- query(repo, @fenced_mark_merged, [id, state, epoch]) do
        case result.num_rows do
          1 -> :ok
          0 -> refused_mark(repo, id, branch, epoch)
        end
      end
    end

    def mark_merged(%Branch{} = branch, config) do
      with {:ok, repo} <- repo(config),
           {:ok, id} <- dump_id(branch.id),
           {:ok, state} <- Codec.encode_state(%{branch | status: :merged}),
           {:ok, result} <-
             query(repo, @mark_merged, [
               id,
               Atom.to_string(branch.domain),
               branch.name,
               state,
               DateTime.to_naive(branch.inserted_at)
             ]) do
        case result.num_rows do
          1 -> :ok
          0 -> {:error, Ramal.Storage.already_merged(branch.id)}
        end
      end
    end

    # Bumps the epoch and reads the row in one statement, so the state returned is the state as of the epoch it names.
    @claim """
    UPDATE #{@table} SET epoch = epoch + 1 WHERE id = $1
    RETURNING #{@columns}, epoch
    """

    @impl true
    def claim(id, config) do
      with {:ok, repo} <- repo(config),
           {:ok, uuid} <- cast_id(id),
           {:ok, result} <- query(repo, @claim, [uuid]) do
        claimed(result.rows, id)
      else
        :not_a_uuid ->
          {:error, Error.new(:not_found, "no branch with id #{inspect(id)}", %{id: id})}

        error ->
          error
      end
    end

    defp claimed([row], _id) do
      {epoch, row} = List.pop_at(row, -1)

      with {:ok, branch} <- row |> row_to_map() |> decode(), do: {:ok, %{branch | epoch: epoch}}
    end

    defp claimed([], id),
      do: {:error, Error.new(:not_found, "no branch with id #{inspect(id)}", %{id: id})}

    @impl true
    def fetch(id, config) do
      with {:ok, repo} <- repo(config),
           {:ok, uuid} <- cast_id(id),
           {:ok, result} <- query(repo, "SELECT #{@columns} FROM #{@table} WHERE id = $1", [uuid]) do
        case result.rows do
          [row] -> row |> row_to_map() |> decode()
          [] -> {:error, Error.new(:not_found, "no branch with id #{inspect(id)}", %{id: id})}
        end
      else
        :not_a_uuid ->
          {:error, Error.new(:not_found, "no branch with id #{inspect(id)}", %{id: id})}

        error ->
          error
      end
    end

    @impl true
    def delete(id, config) do
      with {:ok, repo} <- repo(config),
           {:ok, uuid} <- dump_id(id),
           {:ok, _result} <- query(repo, "DELETE FROM #{@table} WHERE id = $1", [uuid]) do
        :ok
      end
    end

    @impl true
    def list(domain, filters, config) do
      with {:ok, repo} <- repo(config),
           {:ok, where, params} <- list_filter(domain, filters),
           {:ok, result} <-
             query(
               repo,
               "SELECT #{@columns} FROM #{@table} WHERE #{where} ORDER BY inserted_at, id",
               params
             ) do
        {:ok, result.rows |> Enum.flat_map(&decode_listed(&1, domain))}
      end
    end

    # One row that cannot be read (written by a newer Ramal, or damaged) must not hide every other branch of the
    # domain from `Ramal.list/2` and the inspector. It is skipped and announced; `get/1` of its id still returns the error.
    defp decode_listed(row, domain) do
      {columns, _state} = mapped = row_to_map(row)

      case decode(mapped) do
        {:ok, branch} ->
          [branch]

        {:error, error} ->
          Ramal.Telemetry.storage(:unreadable, %{
            branch_id: columns.id,
            domain: domain,
            message: error.message
          })

          []
      end
    end

    # The owner is compared in the database on its JSON form, in the generated `owner` column, so the branches of other
    # owners are never decoded and the hash index serves the lookup. A branch stored before owners existed has no
    # `owner` key and counts as unowned. `Ramal.list/2` checks the decoded owner again, so a term whose JSON form is not
    # canonical can only make this miss, never leak.
    defp list_filter(domain, filters) do
      base = {"domain = $1", [Atom.to_string(domain)]}

      with {:ok, filtered} <- by_status(base, Keyword.get(filters, :status)) do
        by_owner(filtered, Keyword.fetch(filters, :owner))
      end
    end

    defp by_status(filter, nil), do: {:ok, filter}

    defp by_status({where, params}, status) do
      {:ok, {where <> " AND status = $#{length(params) + 1}", params ++ [Atom.to_string(status)]}}
    end

    defp by_owner({where, params}, :error), do: {:ok, where, params}

    defp by_owner({where, params}, {:ok, nil}), do: {:ok, where <> " AND owner IS NULL", params}

    defp by_owner({where, params}, {:ok, owner}) do
      with {:ok, json} <- Codec.encode_owner(owner) do
        {:ok, where <> " AND owner = $#{length(params) + 1}::jsonb", params ++ [json]}
      end
    end

    @impl true
    def count(domain, statuses, config) do
      with {:ok, repo} <- repo(config),
           {:ok, result} <-
             query(
               repo,
               "SELECT count(*) FROM #{@table} WHERE domain = $1 AND status = ANY($2::text[])",
               [Atom.to_string(domain), Enum.map(statuses, &Atom.to_string/1)]
             ) do
        [[count]] = result.rows
        {:ok, count}
      end
    end

    # A write that updated no row says why by looking at the row: the epoch it holds, and whether it is merged.
    defp fenced_or_guarded(repo, id, branch, epoch) do
      case query(repo, "SELECT epoch, status FROM #{@table} WHERE id = $1", [id]) do
        {:ok, %{rows: [[^epoch, "merged"]]}} -> :ok
        {:ok, _other} -> {:error, Ramal.Storage.fenced(branch.id, epoch)}
        {:error, _} = error -> error
      end
    end

    # An append that stored nothing: the row is gone, or another process claimed the branch.
    defp refused_append(repo, id, branch, epoch) do
      case query(repo, "SELECT epoch FROM #{@table} WHERE id = $1", [id]) do
        {:ok, %{rows: [[_other]]}} ->
          {:error, Ramal.Storage.fenced(branch.id, epoch)}

        {:ok, _no_row} ->
          {:error,
           Error.new(
             :storage,
             "branch #{inspect(branch.id)} is not stored, so it has no write log"
           )}

        {:error, _} = error ->
          error
      end
    end

    defp refused_mark(repo, id, branch, epoch) do
      case query(repo, "SELECT epoch, status FROM #{@table} WHERE id = $1", [id]) do
        {:ok, %{rows: [[^epoch, "merged"]]}} -> {:error, Ramal.Storage.already_merged(branch.id)}
        {:ok, _other} -> {:error, Ramal.Storage.fenced(branch.id, epoch)}
        {:error, _} = error -> error
      end
    end

    defp row_to_map([id, domain, name, status, state]) do
      {%{id: Ecto.UUID.load!(id), domain: domain, name: name, status: status}, state}
    end

    defp decode({columns, state}), do: Codec.decode_state(columns, state)

    defp collect(results) do
      Enum.reduce_while(results, {:ok, []}, fn
        {:ok, branch}, {:ok, acc} -> {:cont, {:ok, [branch | acc]}}
        {:error, _} = error, _acc -> {:halt, error}
      end)
      |> case do
        {:ok, branches} -> {:ok, Enum.reverse(branches)}
        error -> error
      end
    end

    defp repo(config) do
      case Keyword.fetch(config, :repo) do
        {:ok, repo} when is_atom(repo) ->
          {:ok, repo}

        _missing ->
          {:error,
           Error.new(
             :storage,
             "Ramal.Storage.Postgres needs the repo: {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}"
           )}
      end
    end

    defp dump_id(id) do
      case Ecto.UUID.dump(id) do
        {:ok, uuid} ->
          {:ok, uuid}

        :error ->
          {:error,
           Error.new(
             :storage,
             "branch id #{inspect(id)} is not a UUID, which this storage requires"
           )}
      end
    end

    defp cast_id(id) do
      case Ecto.UUID.dump(id) do
        {:ok, uuid} -> {:ok, uuid}
        :error -> :not_a_uuid
      end
    end

    defp query(repo, sql, params) do
      case SQL.query(repo, sql, params) do
        {:ok, result} -> {:ok, result}
        {:error, exception} -> {:error, failed(exception)}
      end
    rescue
      exception -> {:error, failed(exception)}
    end

    defp failed(exception) do
      Error.new(
        :storage,
        "Postgres storage failed: #{Exception.message(exception)}; are the ramal_branches table and, for a durable branch, the ramal_branch_writes table migrated (mix ramal.gen.migration writes what is missing)?",
        %{exception: exception}
      )
    end
  end
end
