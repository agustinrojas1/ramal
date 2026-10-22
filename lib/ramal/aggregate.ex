defmodule Ramal.Aggregate do
  @moduledoc """
  Aggregates computed in Elixir over a list of records. `Ramal.aggregate/4` uses it on the rows a read returns inside
  a branch, because the aggregates Ash hands to the data layer do not see the branch's overlay.

  The kinds follow Ash's: `:count` (rows), `:exists`, `:sum`, `:min`, `:max` and `:avg`. As in SQL, `nil` values are
  skipped, and `:sum`, `:min`, `:max` and `:avg` of no values are `nil`. `:sum` of decimals is a `Decimal`, `:avg` is a
  float (Ash types it as `:float`, `lib/ash/query/aggregate.ex`). `:min` and `:max` order values the way a runtime sort
  does (the runtime sort in Ash.Actions.Sort), so dates, decimals and strings compare by their type.

  ## Example

      iex> records = [%{head: 30}, %{head: nil}, %{head: 12}]
      iex> Ramal.Aggregate.compute(:sum, :head, records, Ramal.Test.Farm.Herd)
      42
      iex> Ramal.Aggregate.compute(:count, nil, records, Ramal.Test.Farm.Herd)
      3
  """

  alias Ash.Actions.Sort
  alias Ash.Resource.Info

  @kinds [:count, :exists, :sum, :min, :max, :avg]

  @typedoc "An aggregate kind."
  @type kind :: :count | :exists | :sum | :min | :max | :avg

  @doc """
  The kinds `compute/4` knows.

  ## Example

      iex> Ramal.Aggregate.kinds()
      [:count, :exists, :sum, :min, :max, :avg]
  """
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc """
  Computes `kind` over `records`, which are rows of `resource`. `field` is the attribute to aggregate; `:count` and
  `:exists` ignore it. Raises `ArgumentError` for an unknown kind or a field that is not an attribute of `resource`.

  ## Example

      iex> Ramal.Aggregate.compute(:max, :head, [%{head: 30}, %{head: 12}], Ramal.Test.Farm.Herd)
      30
      iex> Ramal.Aggregate.compute(:avg, :head, [%{head: 30}, %{head: 12}], Ramal.Test.Farm.Herd)
      21.0
      iex> Ramal.Aggregate.compute(:exists, nil, [], Ramal.Test.Farm.Herd)
      false
  """
  @spec compute(kind, atom | nil, [map], module) :: term
  def compute(:count, _field, records, _resource), do: length(records)
  def compute(:exists, _field, records, _resource), do: records != []

  def compute(kind, field, records, resource) when kind in [:sum, :min, :max, :avg] do
    validate!(kind, field, resource)

    values =
      records
      |> Enum.map(&Map.fetch!(&1, field))
      |> Enum.reject(&is_nil/1)

    reduce(kind, field, values, resource)
  end

  def compute(kind, field, _records, resource), do: validate!(kind, field, resource)

  @doc """
  Raises `ArgumentError` unless `kind` is known and, for the kinds that read a value, `field` is an attribute of
  `resource`. `Ramal.aggregate/4` calls it before reading so that both of its paths refuse the same input.

  ## Example

      iex> Ramal.Aggregate.validate!(:sum, :head, Ramal.Test.Farm.Herd)
      :ok
      iex> Ramal.Aggregate.validate!(:count, nil, Ramal.Test.Farm.Herd)
      :ok
  """
  @spec validate!(kind, atom | nil, module) :: :ok
  def validate!(kind, _field, _resource) when kind in [:count, :exists], do: :ok

  def validate!(kind, field, resource) when kind in [:sum, :min, :max, :avg] do
    unless is_atom(field) and not is_nil(field) and Info.attribute(resource, field) do
      raise ArgumentError,
            "#{inspect(field)} is not an attribute of #{inspect(resource)}; aggregates here cover attributes only"
    end

    :ok
  end

  def validate!(kind, _field, _resource) do
    raise ArgumentError, "unknown aggregate kind #{inspect(kind)}; use one of #{inspect(@kinds)}"
  end

  defp reduce(_kind, _field, [], _resource), do: nil
  defp reduce(:sum, _field, values, _resource), do: sum(values)
  defp reduce(:avg, _field, values, _resource), do: average(values)

  defp reduce(kind, field, values, resource) do
    # runtime_sort loads calculations onto records, so it needs real resource structs and not plain maps.
    sorted =
      values
      |> Enum.map(&struct(resource, [{field, &1}]))
      |> Sort.runtime_sort([{field, :asc}], resource: resource, domain: Info.domain(resource))

    edge = if kind == :min, do: List.first(sorted), else: List.last(sorted)
    Map.fetch!(edge, field)
  end

  defp sum(values) do
    if Enum.any?(values, &is_struct(&1, Decimal)) do
      values |> Enum.map(&to_decimal/1) |> Enum.reduce(&Decimal.add/2)
    else
      Enum.sum(values)
    end
  end

  defp average(values) do
    total = sum(values)
    total = if is_struct(total, Decimal), do: Decimal.to_float(total), else: total
    total / length(values)
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
end
