defmodule Ramal.Error do
  @moduledoc """
  The error every Ramal function returns as `{:error, %Ramal.Error{}}`.

  `reason` is an atom from the closed list below, so a host can match on it. `message` says what happened in words
  a developer can act on. `details` carries the data behind the message, for example the stale rows.

  | reason | meaning |
  |---|---|
  | `:not_found` | no branch with that id, in memory or in storage |
  | `:not_open` | the branch is merged or discarded |
  | `:stale` | the base moved under rows the branch read (`details.rows`) |
  | `:database_generated_key` | a branch cannot create a row whose primary key the database generates |
  | `:bulk_unsupported` | a bulk action inside a branch that does not return records |
  | `:branch_too_large` | the branch process exceeded `max_heap_size` and was stopped |
  | `:no_branchable_resources` | the domain has no resource that opted in with `Ramal.Resource` |
  | `:nested_branch` | `Ramal.run/2` was called inside another `Ramal.run/2` |
  | `:missing_snapshot` | an overlay entry that needs the base row as first seen has none recorded |
  | `:storage` | the storage backend failed |

  ## Example

      iex> error = Ramal.Error.new(:not_open, "branch b1 is already merged", %{status: :merged})
      iex> {error.reason, error.message, error.details}
      {:not_open, "branch b1 is already merged", %{status: :merged}}
      iex> Exception.message(error)
      "branch b1 is already merged"
  """

  @type reason ::
          :not_found
          | :not_open
          | :stale
          | :database_generated_key
          | :bulk_unsupported
          | :branch_too_large
          | :no_branchable_resources
          | :nested_branch
          | :missing_snapshot
          | :storage

  @type t :: %__MODULE__{reason: reason, message: String.t(), details: map}

  defexception [:reason, :message, details: %{}]

  @doc """
  Builds an error.

  ## Example

      iex> Ramal.Error.new(:not_found, "no branch with id \\"b1\\"").reason
      :not_found
  """
  @spec new(reason, String.t(), map) :: t
  def new(reason, message, details \\ %{}) when is_atom(reason) and is_binary(message) do
    %__MODULE__{reason: reason, message: message, details: details}
  end
end
