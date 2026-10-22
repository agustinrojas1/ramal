defmodule Ramal.Current do
  @moduledoc false
  # The carrier of "the current branch" for the calling process. See docs/adr/0002-current-branch-carrier.md.
  #
  # Only the branch id is carried, never the struct: the struct changes with every write and the process that owns the
  # truth is the branch server. The process dictionary is the ambient source, because Ash has no ambient context and a
  # plain `Ash.update!/3` inside `Ramal.run/2` passes no options.

  @key :ramal_current_branch_id

  @spec id() :: String.t() | nil
  def id, do: Process.get(@key)

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
