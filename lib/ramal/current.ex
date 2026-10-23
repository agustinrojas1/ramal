defmodule Ramal.Current do
  @moduledoc false
  # The carrier of "the current branch" for the calling process. See docs/adr/0002-current-branch-carrier.md.
  #
  # Only the branch id is carried, never the struct: the struct changes with every write and the process that owns the
  # truth is the branch server. The process dictionary is the ambient source, because Ash has no ambient context and a
  # plain `Ash.update!/3` inside `Ramal.run/2` passes no options.

  @key :ramal_current_branch_id
  @shared_key :ramal_branch_id

  @spec id() :: String.t() | nil
  def id, do: Process.get(@key)

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
