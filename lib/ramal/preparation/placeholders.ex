defmodule Ramal.Preparation.Placeholders do
  @moduledoc false
  # Orders the placeholder keys of generated integer primary keys after every real key, as the merge will (ADR 0042).
  #
  # A row whose key the database generates has `-2^31 + n` in the branch (`Ramal.Branch.placeholder/2`), so a sort or a
  # keyset comparison on that key put the branch's new rows before the base's, while the merged database puts them
  # after (the sequence gives them keys above every existing one). Both are done in Elixir on the patched list
  # (`Ramal.Preparation`, `Ramal.Preparation.Paged`), so the key is *lifted* for the comparison: a placeholder becomes
  # `2^63 + n`, above any `int8`, keeping creation order, and goes back to its own value afterwards. The rows keep their
  # placeholder in everything the caller sees.
  #
  # Only a single `generated? true` primary key of type `Ash.Type.Integer` has placeholders that are numbers; a UUID
  # placeholder is random, and so is a real UUID's position, so there is no order to match. A negative integer that is
  # not a placeholder is mistaken for one when it lies in `[-2^31, 0)`, the same caveat ADR 0042 gives for the merge.

  alias Ash.Resource.Info

  @base -2_147_483_648
  @lift 9_223_372_036_854_775_808 - @base

  @doc """
  The name of the primary key of `resource` when it is a single generated integer, which has placeholders that sort;
  `nil` otherwise.
  """
  @spec field(module) :: atom | nil
  def field(resource) do
    with [field] <- Info.primary_key(resource),
         %{type: Ash.Type.Integer, generated?: true} <- Info.attribute(resource, field) do
      field
    else
      _ -> nil
    end
  end

  @doc """
  Runs `fun` on `rows` with their placeholder keys lifted above the real ones, and gives back what it returns with the
  keys restored, when `sort` orders by the key of `resource`; `fun.(rows)` otherwise. `fun` must return
  `{:ok, rows}` or an error.
  """
  @spec sorted([struct], [term], module, ([struct] -> {:ok, [struct]} | {:error, term})) ::
          {:ok, [struct]} | {:error, term}
  def sorted(rows, sort, resource, fun) do
    field = field(resource)

    if field != nil and Enum.any?(sort || [], &match?({^field, _}, &1)) and
         Enum.any?(rows, &placeholder?(&1, field)) do
      with {:ok, sorted} <- fun.(Enum.map(rows, &lift_row(&1, field))) do
        {:ok, Enum.map(sorted, &unlift_row(&1, field))}
      end
    else
      fun.(rows)
    end
  end

  @doc """
  How a row is shown to the keyset filter of `Ash.Page.Keyset.filter/4`, and `filter` with the key values of its
  comparisons lifted the same way, so a cursor that names a placeholder compares as the merged database would. The view
  is the identity for a resource without placeholders that sort.
  """
  @spec keyset_view(term, module) :: {(struct -> struct), term}
  def keyset_view(filter, resource) do
    case field(resource) do
      nil -> {& &1, filter}
      field -> {&lift_row(&1, field), lift_filter(filter, field)}
    end
  end

  @doc "The value `key` has in a comparison: a placeholder lifted above every real key, any other key as it is."
  @spec lift(term) :: term
  def lift(key) when is_integer(key) and key >= @base and key < 0, do: key + @lift
  def lift(key), do: key

  defp unlift(key) when is_integer(key) and key >= @base + @lift, do: key - @lift
  defp unlift(key), do: key

  defp placeholder?(row, field), do: lift(Map.get(row, field)) != Map.get(row, field)

  defp lift_row(row, field), do: Map.update!(row, field, &lift/1)
  defp unlift_row(row, field), do: Map.update!(row, field, &unlift/1)

  # The comparisons `Ash.Page.Keyset` builds are `{%Ash.Query.Ref{attribute: key}, [gt: value]}` inside `or:` lists.
  defp lift_filter(
         {%Ash.Query.Ref{attribute: %{name: field}, relationship_path: []} = ref, ops},
         field
       )
       when is_list(ops) do
    {ref, Enum.map(ops, fn {operator, value} -> {operator, lift(value)} end)}
  end

  defp lift_filter(list, field) when is_list(list), do: Enum.map(list, &lift_filter(&1, field))

  defp lift_filter(tuple, field) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&lift_filter(&1, field)) |> List.to_tuple()

  defp lift_filter(other, _field), do: other
end
