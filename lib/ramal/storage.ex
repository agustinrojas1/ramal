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

  @doc "The branches of a domain, optionally filtered by `status:`, oldest first."
  @callback list(domain :: module, filters :: keyword, config) ::
              {:ok, [Branch.t()]} | {:error, Error.t()}
end
