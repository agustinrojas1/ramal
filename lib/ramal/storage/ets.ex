defmodule Ramal.Storage.ETS do
  @moduledoc """
  Keeps branches in an ETS table owned by `Ramal.Supervisor`. The default backend in tests and development.

  Everything is lost when the supervisor stops. Reads and writes go straight to the table from the calling process,
  so the backend adds no bottleneck.

  The write log of a durable branch (ADR 0048) is in a second table, an ordered set keyed by `{branch_id, seq}`: the
  first one is scanned whole by `list/3` and `count/3`, which must not meet deltas. It makes a durable branch survive
  the death of its process, which is all an ETS table can promise.

  The table belongs to one node, so this backend cannot be shared by a cluster. It still fences by epoch
  (`c:Ramal.Storage.claim/2`), which lets `Ramal.Supervisor` run with `cluster: true` on a single node, for tests. The
  epochs are counters in the supervisor's own table, and a check and the write that follows it are not one atomic step.

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

  @doc """
  The name of the table of the write logs. `Ramal.Supervisor` creates it.

  ## Example

      iex> Ramal.Storage.ETS.writes_table()
      Ramal.Storage.ETS.Writes
  """
  @spec writes_table() :: atom
  def writes_table, do: Module.concat(__MODULE__, Writes)

  @impl true
  def put(%{epoch: epoch} = branch, _config) when is_integer(epoch) do
    with :ok <- check_epoch(branch.id, epoch) do
      :ets.insert(table(), {branch.id, %{branch | epoch: nil}})
      drop_covered(branch)
      :ok
    end
  rescue
    ArgumentError -> unavailable()
  end

  def put(branch, _config) do
    :ets.insert(table(), {branch.id, branch})
    drop_covered(branch)
    :ok
  rescue
    ArgumentError -> unavailable()
  end

  @impl true
  def append(branch, seq, delta, _config) do
    with :ok <- check_held(branch) do
      :ets.insert(writes_table(), {{branch.id, seq}, delta})
      :ok
    end
  rescue
    ArgumentError -> unavailable()
  end

  @impl true
  def writes_after(branch, _config) do
    id = branch.id

    with :ok <- check_held(branch) do
      # The key's first element is bound, so an ordered set walks only this branch's deltas, already in `seq` order.
      deltas =
        :ets.select(writes_table(), [
          {{{id, :"$1"}, :"$2"}, [{:>, :"$1", branch.wal}], [{{:"$1", :"$2"}}]}
        ])

      {:ok, deltas}
    end
  rescue
    ArgumentError -> unavailable()
  end

  defp drop_covered(%{durable: true, id: id, wal: wal}) when wal > 0 do
    :ets.select_delete(writes_table(), [{{{id, :"$1"}, :_}, [{:"=<", :"$1", wal}], [true]}])
  end

  defp drop_covered(_not_durable), do: :ok

  @impl true
  def claim(id, _config) do
    case :ets.lookup(table(), id) do
      [{^id, branch}] ->
        epoch = :ets.update_counter(Ramal.Supervisor.table(), {:epoch, id}, 1, {{:epoch, id}, 0})
        {:ok, %{branch | epoch: epoch}}

      [] ->
        {:error, Error.new(:not_found, "no branch with id #{inspect(id)}", %{id: id})}
    end
  rescue
    ArgumentError -> unavailable()
  end

  defp check_epoch(id, epoch) do
    case :ets.lookup(Ramal.Supervisor.table(), {:epoch, id}) do
      [{_key, ^epoch}] -> :ok
      _other -> {:error, Ramal.Storage.fenced(id, epoch)}
    end
  end

  # ETS has no transaction to join, so a merge whose commit fails after this call puts the open branch back (ADR 0035).
  # Only the process holding the merge claim calls this for a branch, so the lookup and the insert do not race.
  @impl true
  def mark_merged(branch, _config) do
    with :ok <- check_held(branch) do
      case :ets.lookup(table(), branch.id) do
        [{_id, %{status: :merged}}] ->
          {:error, Ramal.Storage.already_merged(branch.id)}

        _open_or_missing ->
          :ets.insert(table(), {branch.id, %{branch | status: :merged, epoch: nil}})
          :ok
      end
    end
  rescue
    ArgumentError -> unavailable()
  end

  defp check_held(%{epoch: nil}), do: :ok
  defp check_held(%{id: id, epoch: epoch}), do: check_epoch(id, epoch)

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
    :ets.select_delete(writes_table(), [{{{id, :_}, :_}, [], [true]}])
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
