defmodule Ramal.Storage.ETS do
  @moduledoc """
  Keeps branches in an ETS table owned by `Ramal.Supervisor`. The default backend in tests and development.

  Everything is lost when the supervisor stops. Reads and writes go straight to the table from the calling process,
  so the backend adds no bottleneck.

  ## Example

      iex> Ramal.Storage.ETS.table()
      Ramal.Storage.ETS
  """

  @behaviour Ramal.Storage

  alias Ramal.Error

  @doc """
  The name of the table. `Ramal.Supervisor` creates it.

  ## Example

      iex> Ramal.Storage.ETS.table()
      Ramal.Storage.ETS
  """
  @spec table() :: atom
  def table, do: __MODULE__

  @impl true
  def put(branch, _config) do
    :ets.insert(table(), {branch.id, branch})
    :ok
  rescue
    ArgumentError -> unavailable()
  end

  # ETS has no transaction to join, so a merge whose commit fails after this call puts the open branch back (ADR 0035).
  # Only the process holding the merge claim calls this for a branch, so the lookup and the insert do not race.
  @impl true
  def mark_merged(branch, _config) do
    case :ets.lookup(table(), branch.id) do
      [{_id, %{status: :merged}}] ->
        {:error, Ramal.Storage.already_merged(branch.id)}

      _open_or_missing ->
        :ets.insert(table(), {branch.id, %{branch | status: :merged}})
        :ok
    end
  rescue
    ArgumentError -> unavailable()
  end

  @impl true
  def fetch(id, _config) do
    case :ets.lookup(table(), id) do
      [{^id, branch}] -> {:ok, branch}
      [] -> {:error, Error.new(:not_found, "no branch with id #{inspect(id)}", %{id: id})}
    end
  rescue
    ArgumentError -> unavailable()
  end

  @impl true
  def delete(id, _config) do
    :ets.delete(table(), id)
    :ok
  rescue
    ArgumentError -> unavailable()
  end

  @impl true
  def list(domain, filters, _config) do
    status = Keyword.get(filters, :status)

    branches =
      table()
      |> :ets.tab2list()
      |> Enum.map(fn {_id, branch} -> branch end)
      |> Enum.filter(
        &(&1.domain == domain and (is_nil(status) or &1.status == status) and owned?(&1, filters))
      )
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    {:ok, branches}
  rescue
    ArgumentError -> unavailable()
  end

  @impl true
  def count(_domain, [], _config), do: {:ok, 0}

  def count(domain, statuses, _config) do
    # `select_count` runs the match inside ETS, so the branches (whole overlays) are not copied into the caller.
    guard =
      Enum.reduce(statuses, false, fn status, acc -> {:orelse, {:"=:=", :"$1", status}, acc} end)

    {:ok, :ets.select_count(table(), [{{:_, %{domain: domain, status: :"$1"}}, [guard], [true]}])}
  rescue
    ArgumentError -> unavailable()
  end

  defp owned?(branch, filters) do
    case Keyword.fetch(filters, :owner) do
      {:ok, owner} -> branch.owner == owner
      :error -> true
    end
  end

  defp unavailable do
    {:error,
     Error.new(
       :storage,
       "the ETS table #{inspect(table())} does not exist; is Ramal.Supervisor running?"
     )}
  end
end
