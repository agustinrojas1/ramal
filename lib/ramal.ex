defmodule Ramal do
  @moduledoc """
  Data branches as BEAM processes.

  A branch is a process holding an overlay over an Ash application's data. Inside `run/2`, reads see the base
  data patched with the branch's changes, and writes land in the overlay instead of the data layer. A branch can
  be forked, diffed, merged back through the application's own actions, or discarded.

  Add `Ramal.Supervisor` to the application's supervision tree first, then:

      {:ok, branch} = Ramal.branch(MyApp.Farm, name: "move herd R7 to paddock L18")

      {:ok, herds} = Ramal.run(branch, fn -> Ash.read!(MyApp.Farm.Herd) end)

      :ok = Ramal.discard(branch)

  Every function that takes a branch also takes its id, and starts the branch process from storage when it is
  not running, so callers never need to know whether a branch is in memory.

  Fork, diff and merge arrive in later 0.1 issues; see `docs/ROADMAP.md`.
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
        {:ok, Current.with_branch(id, fun)}
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
      {:ok, config.storage.list(domain, Keyword.take(opts, [:status]), config.storage_config)}
    end
  end

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
