defmodule Ramal.Storage do
  @moduledoc """
  Where branches are kept while no process holds them.

  A branch process persists its state here when it unloads (after `idle_timeout`), when the supervisor shuts down,
  and when a branch is created, merged or discarded. Writes between two of those moments live only in the process.
  The process loads from here on demand, so the host never needs to know whether a branch is in memory.

  Every callback receives the storage config as its last argument: whatever options were given to `Ramal.Supervisor`
  (the Postgres backend reads `:repo` from it). Implementations return `{:error, %Ramal.Error{reason: :storage}}` for
  failures of the backend itself.

  | backend | where | lifetime |
  |---|---|---|
  | `Ramal.Storage.ETS` | an ETS table owned by `Ramal.Supervisor` | until the supervisor stops |
  | `Ramal.Storage.Postgres` | the `ramal_branches` table | durable |

  ## Example

      iex> Ramal.Storage.ETS in [Ramal.Storage.ETS, Ramal.Storage.Postgres]
      true
  """

  alias Ramal.{Branch, Error}

  @type config :: keyword

  @doc "Stores the branch, replacing any earlier copy with the same id."
  @callback put(Branch.t(), config) :: :ok | {:error, Error.t()}

  @doc "The branch with that id, or `{:error, %Ramal.Error{reason: :not_found}}`."
  @callback fetch(id :: String.t(), config) :: {:ok, Branch.t()} | {:error, Error.t()}

  @doc "Removes the branch. Removing a missing id is not an error."
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

  @optional_callbacks count: 3, mark_merged: 2

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
