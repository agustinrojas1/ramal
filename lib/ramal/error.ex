defmodule Ramal.Error do
  @moduledoc """
  The error every Ramal function returns as `{:error, %Ramal.Error{}}`.

  When a Ramal error is raised inside an Ash action (for example a bulk action inside a branch), Ash returns it in
  the `errors` of an `Ash.Error.Invalid`; `find/2` pulls it out.

  `reason` is an atom from the closed list below, so a host can match on it. `message` says what happened in words
  a developer can act on. `details` carries the data behind the message, for example the stale rows.

  | reason | meaning |
  |---|---|
  | `:not_found` | no branch with that id, in memory or in storage |
  | `:not_open` | the branch is not in the status the call needs: open for `run/2`, `fork/2`, `merge/2` and `propose/2`, proposed for `approve/2` and `reject/2` |
  | `:stale` | the base moved under rows the branch read (`details.rows`) |
  | `:merge_failed` | a replayed action failed; `details` has `index`, `type`, `resource`, `action` and the Ash `error` |
  | `:database_generated_key` | a branch cannot create a row whose primary key the database generates |
  | `:bulk_unsupported` | a bulk create, update or destroy inside a branch |
  | `:upsert_unsupported` | an upsert inside a branch |
  | `:atomic_unsupported` | an atomic update whose expression cannot be evaluated in Elixir inside a branch (`details.attribute`) |
  | `:partial_record` | an update or destroy of a record read with `Ash.Query.select/2`, whose full row could not be read inside the branch |
  | `:multitenancy_unsupported` | a multitenant resource used with a tenant inside a branch that has none (create it with `tenant:`) |
  | `:tenant_mismatch` | a multitenant resource used with a tenant other than the branch's (`details.tenant`, `branch_tenant`) |
  | `:branch_too_large` | the branch process exceeded `max_heap_size` and was stopped |
  | `:no_branchable_resources` | the domain has no resource that opted in with `Ramal.Resource` |
  | `:branch_mismatch` | a changeset or query was built under one branch (or none) and run under another (`details.built`, `current`) |
  | `:task_in_action` | a captured write from a task that a hook of another captured action started |
  | `:unbranchable_resources` | the domain has resources that neither use `Ramal.Resource` nor opt out of it (`details.resources`) |
  | `:nested_branch` | `Ramal.run/2` was called inside another `Ramal.run/2`, or `Ramal.merge/2` inside one |
  | `:row_busy` | a write to a row that another process's action wrote in the branch and has not ended (`details.resource`, `key`); retry once it has |
  | `:missing_snapshot` | an overlay entry that needs the base row as first seen has none recorded |
  | `:limit_reached` | `Ramal.branch/2` or `Ramal.fork/2` was refused by `:max_active_branches` or `:branch_rate` of `Ramal.Supervisor` (`details.limit`, `max`, and `active` or `window`) |
  | `:not_started` | `Ramal.Supervisor` is not running |
  | `:storage` | the storage backend failed |
  | `:timeout` | the branch process did not answer in time (`details.timeout` in ms); the request may still be carried out |

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
          | :merge_failed
          | :database_generated_key
          | :bulk_unsupported
          | :upsert_unsupported
          | :atomic_unsupported
          | :multitenancy_unsupported
          | :tenant_mismatch
          | :partial_record
          | :branch_too_large
          | :no_branchable_resources
          | :branch_mismatch
          | :task_in_action
          | :unbranchable_resources
          | :nested_branch
          | :missing_snapshot
          | :row_busy
          | :limit_reached
          | :not_started
          | :storage
          | :timeout

  @type t :: %__MODULE__{reason: reason, message: String.t(), details: map}

  # A Splode error, so that Ash keeps the struct when a Ramal error is added to a changeset, instead of formatting it
  # into a string. Inside an Ash action it arrives in the `errors` of an `Ash.Error.Invalid`.
  use Splode.Error, fields: [:reason, :message, details: %{}], class: :invalid

  @impl Exception
  def message(%__MODULE__{message: message}), do: message

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

  @doc """
  The first `Ramal.Error` in an error Ash returned, or `nil`.

  Ash wraps the errors of an action in an error class (`Ash.Error.Invalid` and friends) whose `errors` list holds
  them. This looks through that list, so a host can match on the reason without knowing how Ash nested it.

  ## Example

      iex> error = Ramal.Error.new(:bulk_unsupported, "no bulk inside a branch")
      iex> Ramal.Error.find(Ash.Error.to_error_class(error)).reason
      :bulk_unsupported
      iex> Ramal.Error.find(Ash.Error.to_error_class("something else"))
      nil
  """
  @spec find(term) :: t | nil
  def find(%__MODULE__{} = error), do: error
  def find(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &find/1)
  def find(_other), do: nil
end
