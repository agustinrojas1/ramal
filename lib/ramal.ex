defmodule Ramal do
  @moduledoc """
  Data branches as BEAM processes.

  A branch is a process holding an overlay over an Ash application's data. Inside `run/2`, reads see the base
  data patched with the branch's changes, and writes land in the overlay instead of the data layer. A branch can
  be forked, diffed, merged back through the application's own actions, or discarded.

  ## Example

  Add `Ramal.Supervisor` to the application's supervision tree first, then:

      {:ok, branch} = Ramal.branch(MyApp.Farm, name: "move herd R7 to paddock L18")

      {:ok, herds} = Ramal.run(branch, fn -> Ash.read!(MyApp.Farm.Herd) end)

      :ok = Ramal.discard(branch)

  Every function that takes a branch also takes its id, and starts the branch process from storage when it is
  not running, so callers never need to know whether a branch is in memory.

  """

  alias Ramal.{Branch, Current, Error, Resource, Supervisor, Telemetry}
  alias Ramal.Branch.Server

  @type branch_or_id :: Branch.t() | String.t()

  @doc """
  Creates an open branch over `domain` and starts its process.

  ## Options

    * `:name` - a label for people
    * `:metadata` - a map the host uses freely

  Returns `{:error, %Ramal.Error{reason: :not_started}}` when `Ramal.Supervisor` is not running, and
  `:no_branchable_resources` when no resource of the domain uses `Ramal.Resource` (or all of them opted out), since
  such a branch could never change what a read returns.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm, name: "what if", metadata: %{ticket: 42})
      branch.status
      #=> :open
  """
  @spec branch(module, keyword) :: {:ok, Branch.t()} | {:error, Error.t()}
  def branch(domain, opts \\ []) when is_atom(domain) do
    with {:ok, config} <- Supervisor.config(),
         :ok <- ensure_branchable(domain),
         branch = Branch.new(domain, opts),
         :ok <- config.storage.put(branch, config.storage_config),
         {:ok, _pid} <- Server.start(branch, config) do
      Telemetry.branch(:create, branch)
      {:ok, branch}
    end
  end

  @doc """
  Runs `fun` with the branch as the current branch of the calling process and returns `{:ok, result}`.

  The previous state is restored when `fun` returns and also when it raises, throws or exits. Branches do not nest:
  calling `run/2` inside another `run/2` returns `{:error, %Ramal.Error{reason: :nested_branch}}` without running
  `fun`. Tasks started inside `fun` do not inherit the branch; call `run/2` inside the task with the same branch.

  Returns `:not_found` for an unknown id and `:not_open` for a merged or discarded branch.

  Creates, updates and destroys inside `fun` land in the branch instead of the data layer (`Ramal.Capture`), and the
  notifications they produce are dropped unless the resource sets `notify_in_branch? true`.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      {:ok, nil} = Ramal.run(branch, fn -> Ramal.current() && nil end)
  """
  @spec run(branch_or_id, (-> result)) :: {:ok, result} | {:error, Error.t()} when result: term
  def run(branch_or_id, fun) when is_function(fun, 0) do
    id = id_of(branch_or_id)

    if current = Current.id() do
      {:error,
       Error.new(
         :nested_branch,
         "Ramal.run/2 was called inside branch #{inspect(current)}; branches do not nest in 0.1",
         %{current: current, requested: id}
       )}
    else
      with {:ok, branch} <- Server.get(id),
           :ok <- ensure_open(branch) do
        {:ok, collect_notifications(id, fun)}
      end
    end
  end

  @doc """
  Like `run/2` but returns the result and raises `Ramal.Error` instead of returning an error tuple.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      Ramal.run!(branch, fn -> :done end)
      #=> :done
  """
  @spec run!(branch_or_id, (-> result)) :: result when result: term
  def run!(branch_or_id, fun) do
    case run(branch_or_id, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  The branch the calling process is running in, or `nil` outside `run/2`.

  ## Example

      Ramal.current()
      #=> nil
      Ramal.run!(branch, fn -> Ramal.current().id end)
      #=> branch.id
  """
  @spec current() :: Branch.t() | nil
  def current do
    with id when is_binary(id) <- Current.id(),
         {:ok, branch} <- Server.get(id) do
      branch
    else
      _ -> nil
    end
  end

  @doc """
  The branch with that id, with its overlay and log as they are now.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      {:ok, ^branch} = Ramal.get(branch.id)
  """
  @spec get(String.t()) :: {:ok, Branch.t()} | {:error, Error.t()}
  def get(id) when is_binary(id), do: Server.get(id)

  @doc """
  The branches of `domain` as last persisted, oldest first.

  This reads storage and never loads a process, so a branch that is in memory shows the state of its last persist
  (its creation, its last unload, or its status change). Use `get/1` for the live state.

  ## Options

    * `:status` - only branches with that status (`:open`, `:merged`, `:discarded`)

  ## Example

      {:ok, open} = Ramal.list(MyApp.Farm, status: :open)
  """
  @spec list(module, keyword) :: {:ok, [Branch.t()]} | {:error, Error.t()}
  def list(domain, opts \\ []) when is_atom(domain) do
    with {:ok, config} <- Supervisor.config() do
      config.storage.list(domain, Keyword.take(opts, [:status]), config.storage_config)
    end
  end

  @doc """
  Forks a branch: a new open branch, with its own process, that starts with the parent's overlay, log and base.

  The fork sees the parent's changes as of the moment of the fork and nothing after; the parent never sees the fork's.
  Both share the same database. `metadata.forked_from` holds the parent's id.

  ## Options

    * `:name` - default: the parent's name
    * `:metadata` - default: the parent's metadata

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      {:ok, fork} = Ramal.fork(branch, name: "variant")
      fork.metadata.forked_from == branch.id
      #=> true
  """
  @spec fork(branch_or_id, keyword) :: {:ok, Branch.t()} | {:error, Error.t()}
  def fork(branch_or_id, opts \\ []) do
    with {:ok, config} <- Supervisor.config(),
         {:ok, parent} <- Server.get(id_of(branch_or_id)),
         :ok <- ensure_open(parent),
         fork = Branch.fork(parent, opts),
         :ok <- config.storage.put(fork, config.storage_config),
         {:ok, _pid} <- Server.start(fork, config) do
      Telemetry.branch(:fork, fork, %{parent_id: parent.id})
      {:ok, fork}
    end
  end

  @doc """
  The changes a branch holds, as `Ramal.Change` structs in the order the branch first touched each row.

  Never queries the database: updated and deleted rows are compared with the copy the branch kept when it first wrote
  them. A row the branch changed and then changed back is left out. A fork's diff includes what it inherited.

  ## Example

      {:ok, [change]} = Ramal.diff(branch)
      change.kind
      #=> :updated
      change.changes
      #=> %{head: {30, 31}}
  """
  @spec diff(branch_or_id) :: {:ok, [Ramal.Change.t()]} | {:error, Error.t()}
  def diff(branch_or_id) do
    with {:ok, branch} <- branch_or_id |> id_of() |> Server.get() do
      Branch.diff(branch, attributes: &Resource.attributes/1)
    end
  end

  @doc """
  Merges a branch into the database by replaying its log through the application's own actions, in one transaction.

  First every base row the branch read or wrote is compared with what the database holds now; if any changed, the
  merge is refused unless `on_stale` allows it. Then the log is replayed oldest first with real validations and
  policies. If anything fails, nothing is written and the branch stays open. On success the branch is `:merged`, its
  process stops, and the result holds what the replay wrote. See `Ramal.Merge` for the details and the limits.

  ## Options

    * `:actor` - the actor for every replayed action. Default: the actor each write was captured with.
    * `:authorize?` - default `true`
    * `:on_stale` - `:error` (default), `:ignore`, or a function from the stale rows to `:continue` or `:abort`
    * `:mode` - only `:replay`

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      Ramal.run!(branch, fn -> Ash.update!(herd, %{head: 31}, authorize?: false) end)
      {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch, authorize?: false)
  """
  @spec merge(branch_or_id, keyword) :: {:ok, Ramal.Merge.Result.t()} | {:error, Error.t()}
  def merge(branch_or_id, opts \\ []), do: branch_or_id |> id_of() |> Ramal.Merge.run(opts)

  @doc """
  Discards an open branch: its process stops and its overlay and log are dropped.

  The record stays in storage with status `:discarded`, so `list/2` can show it and later calls return
  `:not_open`. Discarding an already discarded branch is a no-op. A merged branch cannot be discarded.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      :ok = Ramal.discard(branch)
      {:error, %Ramal.Error{reason: :not_open}} = Ramal.run(branch, fn -> :never end)
  """
  @spec discard(branch_or_id) :: :ok | {:error, Error.t()}
  def discard(branch_or_id), do: branch_or_id |> id_of() |> Server.discard()

  # Writes inside a branch queue their notifications exactly as writes inside `Ash.transaction/3` do: nothing is sent
  # until the outermost transaction ends. `Ash.transaction/3` with no resources opens no database transaction and,
  # with `return_notifications?: true`, hands the queue back instead of sending it. Only resources that opted in with
  # `notify_in_branch? true` get theirs sent.
  defp collect_notifications(id, fun) do
    {:ok, result, notifications} =
      Ash.transaction([], fn -> Current.with_branch(id, fun) end, return_notifications?: true)

    notifications
    |> Enum.filter(&Resource.notify_in_branch?(&1.resource))
    |> Ash.Notifier.notify()

    result
  end

  defp ensure_branchable(domain) do
    if Resource.branchable_resources(domain) == [] do
      {:error,
       Error.new(
         :no_branchable_resources,
         "#{inspect(domain)} has no resource with `extensions: [Ramal.Resource]` that is branchable; " <>
           "add the extension to the resources a branch should cover",
         %{domain: domain}
       )}
    else
      :ok
    end
  end

  defp id_of(%Branch{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id

  defp ensure_open(%Branch{status: :open}), do: :ok

  defp ensure_open(%Branch{id: id, status: status}) do
    {:error,
     Error.new(:not_open, "branch #{inspect(id)} is #{status}, not open", %{
       id: id,
       status: status
     })}
  end
end
