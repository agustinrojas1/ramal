if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Ramal.Storage.Postgres do
    @moduledoc """
    Keeps branches in the `ramal_branches` table of the host's Postgres, so they survive a restart.

    Add the table with `mix ramal.gen.migration`, give the supervisor the repo, and nothing else changes:

        {Ramal.Supervisor, storage: Ramal.Storage.Postgres, repo: MyApp.Repo}

    One row per branch: `id` (uuid), `domain`, `name`, `status`, `inserted_at` and `updated_at` as columns, and the rest
    in `state` (jsonb) as `Ramal.Storage.Codec` writes it. Branch ids are UUIDs, as `Ramal.Branch.new/2` makes them.
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
    @columns "id, domain, name, status, state"

    @doc """
    The name of the table `mix ramal.gen.migration` creates.

    ## Example

        iex> Ramal.Storage.Postgres.table()
        "ramal_branches"
    """
    @spec table() :: String.t()
    def table, do: @table

    @upsert """
    INSERT INTO #{@table} (id, domain, name, status, state, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $6)
    ON CONFLICT (id) DO UPDATE SET
      domain = EXCLUDED.domain, name = EXCLUDED.name, status = EXCLUDED.status,
      state = EXCLUDED.state, updated_at = now() AT TIME ZONE 'utc'
    """

    @impl true
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
        :ok
      end
    end

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
      {where, params} =
        case Keyword.get(filters, :status) do
          nil ->
            {"domain = $1", [Atom.to_string(domain)]}

          status ->
            {"domain = $1 AND status = $2", [Atom.to_string(domain), Atom.to_string(status)]}
        end

      with {:ok, repo} <- repo(config),
           {:ok, result} <-
             query(
               repo,
               "SELECT #{@columns} FROM #{@table} WHERE #{where} ORDER BY inserted_at, id",
               params
             ) do
        result.rows |> Enum.map(&(&1 |> row_to_map() |> decode())) |> collect()
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
        "Postgres storage failed: #{Exception.message(exception)}; is the ramal_branches table migrated (mix ramal.gen.migration)?",
        %{exception: exception}
      )
    end
  end
end
