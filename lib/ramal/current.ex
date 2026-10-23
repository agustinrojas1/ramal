defmodule Ramal.Current do
  @moduledoc false
  # The carrier of "the current branch" for the calling process. See docs/adr/0002-current-branch-carrier.md.
  #
  # Only the branch id is carried, never the struct: the struct changes with every write and the process that owns the
  # truth is the branch server. The process dictionary is the ambient source, because Ash has no ambient context and a
  # plain `Ash.update!/3` inside `Ramal.run/2` passes no options.

  @key :ramal_current_branch_id
  @shared_key :ramal_branch_id

  @doc """
  The branch of the calling process: the one it entered with `with_branch/2`, or else the one a process it was
  started from is in.

  The second part reads `$callers`, which `Task.async/1`, `Task.async_stream/3`, `Task.Supervisor` and the tasks Ash
  starts itself (bulk actions with `max_concurrency`, relationship loads) all set, and looks the id up in the
  dictionary of those processes. Ash 3.37 offers no other way to carry it: `Ash.ProcessHelpers.transfer_context/2`
  copies only tracer state (`lib/ash/process_helpers.ex`). ADR 0026.
  """
  @spec id() :: String.t() | nil
  def id, do: own_id() || inherited(@key)

  @doc "The branch the calling process entered itself, ignoring the processes it was started from."
  @spec own_id() :: String.t() | nil
  def own_id, do: Process.get(@key)

  @doc """
  The value of `key` in the process dictionary of the nearest process in `$callers` that has one, or `nil`.

  Only processes on this node can be asked. A caller that has exited counts as having none.
  """
  @spec inherited(term) :: term
  def inherited(key) do
    case Process.get(:"$callers") do
      [_ | _] = callers -> Enum.find_value(callers, &dictionary_get(&1, key))
      _none -> nil
    end
  end

  defp dictionary_get(pid, key) when is_pid(pid) and node(pid) == node() do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {^key, value} <- List.keyfind(dictionary, key, 0) do
      value
    else
      _ -> nil
    end
  end

  defp dictionary_get(_pid, _key), do: nil

  @doc """
  Which branch a hook belongs to when it runs at build time, from the process and from the query's or changeset's
  context, and whether the process or the context supplied it (the check at execution time differs, see `verify/2`).
  """
  @spec bind(map) ::
          :none | {:ok, String.t(), :process | :context} | {:conflict, String.t(), String.t()}
  def bind(context) do
    process = id()
    carried = shared_id(context)

    cond do
      process && carried && process != carried -> {:conflict, process, carried}
      process -> {:ok, process, :process}
      carried -> {:ok, carried, :context}
      true -> :none
    end
  end

  @doc """
  The check a hook makes when the query or changeset is executed, against what `bind/1` found when it was built.

  A changeset built under the process's branch must run under the same one, one built with no branch must run with
  none, and one that carries the id in its context runs wherever the process is in no other branch. Anything else is
  a `:branch_mismatch` instead of a write or a read that skips the branch (ADR 0026).
  """
  @spec verify(String.t() | nil, :process | :context | nil, String.t()) ::
          :ok | {:error, Ramal.Error.t()}
  def verify(built, origin, what) do
    current = id()

    ok? =
      case {built, origin} do
        {nil, _} -> current == nil
        {id, :process} -> current == id
        {id, :context} -> current in [nil, id]
      end

    if ok?, do: :ok, else: {:error, mismatch(what, built, current)}
  end

  @doc "The error for a build-time conflict between the process's branch and the one the context carries."
  @spec conflict(String.t(), String.t(), String.t()) :: Ramal.Error.t()
  def conflict(what, process, carried), do: mismatch(what, carried, process)

  defp mismatch(what, built, current) do
    Ramal.Error.new(
      :branch_mismatch,
      "#{what} was built #{describe(built)} but runs #{describe(current)}; Ramal decides when it is built, so build " <>
        "it and run it under the same branch (inside the same Ramal.run/2, or both outside)",
      %{built: built, current: current}
    )
  end

  defp describe(nil), do: "outside any branch"
  defp describe(id), do: "in branch #{inspect(id)}"

  @doc """
  The branch id a hook should use for a query or changeset context.

  The process dictionary wins; the id in `context[:shared]` covers the tasks Ash spawns for relationship loads, which
  do not inherit the process dictionary but do receive the shared context of the query that started them.
  """
  @spec resolve(map) :: String.t() | nil
  def resolve(context), do: id() || shared_id(context)

  @doc "The branch id `Ramal.context/1` put in `context[:shared]`, whatever the calling process is running in."
  @spec shared_id(map) :: String.t() | nil
  def shared_id(context) when is_map(context), do: get_in(context, [:shared, @shared_key])
  def shared_id(_context), do: nil

  @doc "The context map that carries `id` into the queries and changesets Ash derives from this one."
  @spec shared_context(String.t()) :: map
  def shared_context(id), do: %{shared: %{@shared_key => id}}

  @doc """
  Runs `fun` with `id` as the current branch of the calling process and restores the previous state afterwards,
  also when `fun` raises, throws or exits.
  """
  @spec with_branch(String.t(), (-> result)) :: result when result: term
  def with_branch(id, fun) do
    previous = Process.put(@key, id)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp restore(nil), do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end
