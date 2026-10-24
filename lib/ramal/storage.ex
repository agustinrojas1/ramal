defmodule Ramal.Storage do
  @moduledoc """
  Where branches are kept while no process holds them.

  A branch process persists its state here when it unloads (after `idle_timeout`), when the supervisor shuts down,
  and when a branch is created, merged or discarded. Writes between two of those moments live only in the process,
  unless the branch is durable (`durable: true` at `Ramal.branch/2`, ADR 0048): then the writes of every action that
  ends are appended to a write log here before the action returns, and a load reads the snapshot with the log applied.
  The process loads from here on demand, so the host never needs to know whether a branch is in memory.

  Every callback receives the storage config as its last argument: whatever options were given to `Ramal.Supervisor`
  (the Postgres backend reads `:repo` from it). Implementations return `{:error, %Ramal.Error{reason: :storage}}` for
  failures of the backend itself.

  | backend | where | lifetime |
  |---|---|---|
  | `Ramal.Storage.ETS` | an ETS table owned by `Ramal.Supervisor` | until the supervisor stops |
  | `Ramal.Storage.Postgres` | the `ramal_branches` table, and the `ramal_branch_writes` table for the write log | durable |

  Only the Postgres backend serves a cluster of several nodes, because the nodes must share it. Both backends fence
  writes by epoch, see `c:claim/2`.

  ## Example

      iex> Ramal.Storage.ETS in [Ramal.Storage.ETS, Ramal.Storage.Postgres]
      true
  """

  alias Ramal.{Branch, Error}

  @type config :: keyword

  @doc """
  Stores the branch, replacing any earlier copy with the same id. A durable branch (`durable: true`) is stored with
  the `wal` it includes, and this also deletes the deltas of its write log up to that `wal`, which the snapshot covers
  (ADR 0048). The snapshot is written first: a failure in between leaves deltas that `c:writes_after/2` ignores.
  """
  @callback put(Branch.t(), config) :: :ok | {:error, Error.t()}

  @doc "The branch with that id, or `{:error, %Ramal.Error{reason: :not_found}}`."
  @callback fetch(id :: String.t(), config) :: {:ok, Branch.t()} | {:error, Error.t()}

  @doc "Removes the branch, and its write log if it has one. Removing a missing id is not an error."
  @callback delete(id :: String.t(), config) :: :ok | {:error, Error.t()}

  @doc """
  The branches of a domain, optionally filtered by `status:` and `owner:`, oldest first.

  `owner:` is present only when the caller filters; `owner: nil` then means the branches that have no owner. A backend
  that ignores it is still safe, because `Ramal.list/2` checks the owner of what comes back, but it reads and returns
  every branch of the domain.
  """
  @callback list(domain :: module, filters :: keyword, config) ::
              {:ok, [Branch.t()]} | {:error, Error.t()}

  @doc """
  How many branches of a domain have one of the statuses, without loading them.

  Optional. `Ramal.Supervisor`'s `:max_active_branches` limit calls it before every branch is created; a backend that
  does not define it is counted with `list/3`, which reads every stored branch of the domain.
  """
  @callback count(domain :: module, statuses :: [Branch.status()], config) ::
              {:ok, non_neg_integer} | {:error, Error.t()}

  @doc """
  Stores the branch as `:merged`, unless the storage already holds it as merged: then
  `{:error, %Ramal.Error{reason: :not_open, details: %{status: :merged}}}` and nothing is written.

  Optional. `Ramal.merge/2` calls it inside the merge's transaction, after the replay and before the commit, so a
  backend whose writes join that transaction records the merged status atomically with the merge, and a second merge
  of the same branch is refused there even when the process that ran the first one died before it finished (ADR 0035).
  `Ramal.Storage.Postgres` joins the transaction when its repo is the resources' repo. A backend that does not define
  it gets the merged status only from `put/2` once the merge has committed (ADR 0023).
  """
  @callback mark_merged(Branch.t(), config) :: :ok | {:error, Error.t()}

  @doc """
  Loads the branch for a process that is about to hold it, and fences every process that held it before.

  Optional; `Ramal.Supervisor` with `cluster: true` needs it (ADR 0044). It increments the branch's epoch and returns the
  stored branch with `epoch` set to the new value, in one atomic step, so the caller has the state as of that epoch and
  no other. A missing branch is `{:error, %Ramal.Error{reason: :not_found}}`.

  From then on `put/2` and `mark_merged/2` of a branch whose `epoch` is not `nil` are conditional on the stored epoch
  still being that one: a write that finds another returns `{:error, %Ramal.Error{reason: :fenced}}` and changes nothing.
  A branch with `epoch: nil` is written unconditionally, as it is without a cluster. The epoch is not part of the
  branch's state, so `fetch/2` and `list/3` leave it `nil`.
  """
  @callback claim(id :: String.t(), config) :: {:ok, Branch.t()} | {:error, Error.t()}

  @doc """
  Appends one delta to the write log of a durable branch (ADR 0048): what one action that ended added to the branch,
  as `Ramal.Branch.delta/2` builds it. `seq` is the delta's place in the log, one more than the one before it, and
  is never reused for the branch. Returns `:ok` once the delta is stored, because the action that made it returns
  only then; a failure is `{:error, %Ramal.Error{reason: :storage}}` and the action fails with it.

  Optional; a branch can be `durable: true` only on a storage that defines this and `c:writes_after/2`. `branch` is the
  branch as the process holds it. Like `c:put/2`, an append for a branch whose `epoch` is not `nil` is conditional on
  the stored epoch still being that one (`c:claim/2`, ADR 0044): a process that another one replaced stores nothing and
  gets `{:error, %Ramal.Error{reason: :fenced}}`, and the delta of an append that was accepted is there for the process
  that claims the branch next. The check and the write are one step, so no delta of the old process can appear after the
  new one has read the log.

  The delta is a term. A backend that keeps text encodes it with `Ramal.Storage.Codec.encode_delta/1`.
  """
  @callback append(Branch.t(), seq :: pos_integer, Branch.delta(), config) ::
              :ok | {:error, Error.t()}

  @doc """
  The deltas of the write log with a `seq` above `branch.wal`, oldest first, as `{seq, delta}`. A load applies them to
  the snapshot `c:fetch/2` returned, in this order (`Ramal.Branch.apply_delta/3`), which is the order their actions
  ended in. `branch` is the snapshot.

  Optional, with `c:append/4`. A stored snapshot makes the deltas it covers (`seq <= wal`) dead: `c:put/2` deletes
  them, and this callback never returns them, even if the delete did not happen. For a branch whose `epoch` is not `nil`
  it answers `{:error, %Ramal.Error{reason: :fenced}}` when the stored epoch is another one, instead of a log that the
  newer holder may have changed, and `{:error, %Ramal.Error{reason: :not_found}}` when the branch is no longer stored:
  a log read of a deleted branch is not an empty one.
  """
  @callback writes_after(Branch.t(), config) ::
              {:ok, [{pos_integer, Branch.delta()}]} | {:error, Error.t()}

  @optional_callbacks count: 3, mark_merged: 2, claim: 2, append: 4, writes_after: 2

  @doc """
  Whether `storage` can keep the write log of a durable branch: it defines `c:append/4` and `c:writes_after/2`.

  ## Example

      iex> Ramal.Storage.durable?(Ramal.Storage.ETS)
      true
  """
  @spec durable?(module) :: boolean
  def durable?(storage) do
    Code.ensure_loaded?(storage) and function_exported?(storage, :append, 4) and
      function_exported?(storage, :writes_after, 2)
  end

  @doc """
  The error for a durable branch on a storage that cannot keep its write log.

  ## Example

      iex> Ramal.Storage.durability_unsupported(MyApp.Storage).reason
      :durability_unsupported
  """
  @spec durability_unsupported(module) :: Error.t()
  def durability_unsupported(storage) do
    Error.new(
      :durability_unsupported,
      "#{inspect(storage)} cannot keep the write log of a durable branch: it defines neither append/4 nor " <>
        "writes_after/2 (Ramal.Storage). Use Ramal.Storage.Postgres, add the two callbacks, or drop durable: true",
      %{storage: storage}
    )
  end

  @doc """
  The error a fenced write returns: the branch was loaded by another process after the writer loaded it (`c:claim/2`).

  ## Example

      iex> error = Ramal.Storage.fenced("b1", 3)
      iex> {error.reason, error.details}
      {:fenced, %{id: "b1", epoch: 3}}
  """
  @spec fenced(String.t(), non_neg_integer) :: Error.t()
  def fenced(id, epoch) do
    Error.new(
      :fenced,
      "branch #{inspect(id)} was loaded by another process after this one loaded it (epoch #{epoch} is no longer " <>
        "current), so this process may not write it any more; what it held since its last save is lost",
      %{id: id, epoch: epoch}
    )
  end

  @doc """
  The error `c:mark_merged/2` returns for a branch the storage already holds as merged.

  ## Example

      iex> Ramal.Storage.already_merged("b1").details
      %{id: "b1", status: :merged}
  """
  @spec already_merged(String.t()) :: Error.t()
  def already_merged(id) do
    Error.new(
      :not_open,
      "branch #{inspect(id)} is already merged: an earlier merge of it committed, though the process that ran it may " <>
        "have stopped before it finished",
      %{id: id, status: :merged}
    )
  end
end
