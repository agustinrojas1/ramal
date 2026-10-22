defmodule Ramal.Change do
  @moduledoc """
  One row-level difference between a branch and its base, as `Ramal.diff/1` returns it.

  `kind` says whether the branch created, updated or deleted the row. `changes` maps attribute names to
  `{before, after}`: for a created row every `before` is `nil`, for a deleted row every `after` is `nil`, and for an
  updated row only the attributes whose value differs appear.

  ## Example

      iex> %Ramal.Change{
      ...>   resource: MyApp.Herd,
      ...>   key: "R7",
      ...>   kind: :updated,
      ...>   changes: %{paddock_id: {"L07", "L18"}}
      ...> }.changes
      %{paddock_id: {"L07", "L18"}}
  """

  @type kind :: :created | :updated | :deleted

  @type t :: %__MODULE__{
          resource: module,
          key: term,
          kind: kind,
          changes: %{optional(atom) => {before :: term, after_value :: term}}
        }

  @enforce_keys [:resource, :key, :kind]
  defstruct [:resource, :key, :kind, changes: %{}]
end
