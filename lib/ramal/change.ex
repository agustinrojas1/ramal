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

  alias Ash.Resource.Info

  @type kind :: :created | :updated | :deleted

  @type t :: %__MODULE__{
          resource: module,
          key: term,
          kind: kind,
          changes: %{optional(atom) => {before :: term, after_value :: term}}
        }

  @enforce_keys [:resource, :key, :kind]
  defstruct [:resource, :key, :kind, changes: %{}]

  @redacted "[redacted]"

  @doc """
  The change with the values of `sensitive?` attributes replaced by `"[redacted]"`.

  The attribute stays in `changes`, so a reader sees that it changed, but not its before or after value. Use it before
  a diff goes anywhere a person or a model reads it: the inspector and `Ramal.Tools` both do (ADR 0016). Ash only
  redacts sensitive attributes when it inspects a record, so a diff built from the raw values needs this.

  ## Example

      # MyApp.User has `attribute :password_hash, :string, sensitive?: true`
      change = %Ramal.Change{resource: MyApp.User, key: 1, kind: :updated, changes: %{password_hash: {"a", "b"}}}
      Ramal.Change.redact(change).changes
      #=> %{password_hash: {"[redacted]", "[redacted]"}}
  """
  @spec redact(t) :: t
  def redact(%__MODULE__{resource: resource, changes: changes} = change) do
    redacted =
      Map.new(changes, fn {attribute, values} ->
        if sensitive?(resource, attribute),
          do: {attribute, {@redacted, @redacted}},
          else: {attribute, values}
      end)

    %{change | changes: redacted}
  end

  # `Info.field/2` covers attributes, calculations and aggregates; all three carry `sensitive?`.
  defp sensitive?(resource, attribute) do
    Info.resource?(resource) and
      match?(%{sensitive?: true}, Info.field(resource, attribute))
  end
end
