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

    table()
    |> :ets.tab2list()
    |> Enum.map(fn {_id, branch} -> branch end)
    |> Enum.filter(&(&1.domain == domain and (is_nil(status) or &1.status == status)))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp unavailable do
    {:error,
     Error.new(
       :storage,
       "the ETS table #{inspect(table())} does not exist; is Ramal.Supervisor running?"
     )}
  end
end
