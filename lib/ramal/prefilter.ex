defmodule Ramal.Prefilter do
  @moduledoc false
  # A cheap test that rules overlay records out of a query's filter before `Ash.Filter.Runtime` looks at them.
  #
  # `Ash.Filter.Runtime.filter_matches/4` costs a few microseconds per record, and a read inside a branch used to run it
  # on every overlay record of the resource, so a read cost as much as the overlay was large. Most filters are a few
  # comparisons of an attribute with a literal, and for those a record can be ruled out with a plain comparison.
  #
  # The contract is one-sided: `possible?/2` returns `false` only when the filter surely rejects the record, so a
  # record it lets through is still tested by the real runtime and nothing the runtime would match is ever dropped.
  # Everything that is not understood evaluates to `:unknown`, which lets the record through: relationship paths,
  # calculations, aggregates, functions, a `nil` or unloaded value, and values of different kinds.
  #
  # Confirmed against Ash 3.37 (`lib/ash/query/operator/*.ex`, `lib/comparable/comp.ex`): `Eq`, `NotEq`, `LessThan`,
  # `GreaterThan`, `LessThanOrEqual`, `GreaterThanOrEqual` and `In` return `{:known, nil}` for a `nil` side and
  # otherwise compare with `Comp`, whose clause for two binaries, two numbers or two atoms is the plain Elixir operator.
  # `IsNil` is `is_nil(value) == right`. The comparisons here are limited to two binaries, two integers or two atoms,
  # which is where `Comp` is the plain operator; a decimal, a date, a case-insensitive string or a float goes to the
  # runtime. A `MapSet` for `in` is used only when every member is the same kind as the value.

  alias Ash.Query.{BooleanExpression, Not, Ref}

  alias Ash.Query.Operator.{
    Eq,
    GreaterThan,
    GreaterThanOrEqual,
    In,
    IsNil,
    LessThan,
    LessThanOrEqual,
    NotEq
  }

  @comparisons %{
    Eq => :==,
    NotEq => :!=,
    LessThan => :<,
    GreaterThan => :>,
    LessThanOrEqual => :<=,
    GreaterThanOrEqual => :>=
  }

  @typedoc "What `compile/1` returns: plain data, so it can be sent to the branch process."
  @type t ::
          nil
          | boolean
          | :unknown
          | {:and | :or, [t]}
          | {:not, t}
          | {:compare, atom, atom, term}
          | {:in, atom, kind, MapSet.t()}
          | {:nil?, atom, boolean}
  @type kind :: :binary | :integer | :atom

  @doc """
  The plan for a query filter, or `nil` when the query has none (every record passes).

  ## Example

      iex> require Ash.Query
      iex> filter = Ash.Query.filter(Ramal.Test.Farm.Herd, head > 3).filter
      iex> Ramal.Prefilter.compile(filter)
      {:compare, :>, :head, 3}
  """
  @spec compile(Ash.Filter.t() | nil) :: t
  def compile(nil), do: nil
  def compile(%Ash.Filter{expression: expression}), do: expression(expression)
  def compile(_other), do: :unknown

  defp expression(nil), do: nil
  defp expression(boolean) when is_boolean(boolean), do: boolean

  defp expression(%BooleanExpression{op: op, left: left, right: right}) when op in [:and, :or],
    do: {op, [expression(left), expression(right)]}

  defp expression(%Not{expression: inner}), do: {:not, expression(inner)}

  defp expression(%struct{left: %Ref{} = ref, right: literal})
       when is_map_key(@comparisons, struct) do
    with {:ok, field} <- field(ref),
         true <- kind(literal) != nil do
      {:compare, Map.fetch!(@comparisons, struct), field, literal}
    else
      _ -> :unknown
    end
  end

  defp expression(%In{left: %Ref{} = ref, right: %MapSet{} = members}) do
    with {:ok, field} <- field(ref),
         kind when kind != nil <- members |> Enum.map(&kind/1) |> uniform() do
      {:in, field, kind, members}
    else
      _ -> :unknown
    end
  end

  defp expression(%IsNil{left: %Ref{} = ref, right: is_nil?}) when is_boolean(is_nil?) do
    case field(ref) do
      {:ok, field} -> {:nil?, field, is_nil?}
      :error -> :unknown
    end
  end

  defp expression(_other), do: :unknown

  defp field(%Ref{attribute: %Ash.Resource.Attribute{name: name}, relationship_path: []}),
    do: {:ok, name}

  defp field(_ref), do: :error

  defp uniform([kind | rest]) when kind != nil, do: if(Enum.all?(rest, &(&1 == kind)), do: kind)
  defp uniform(_kinds), do: nil

  defp kind(value) when is_binary(value), do: :binary
  defp kind(value) when is_integer(value), do: :integer
  defp kind(value) when is_atom(value) and value != nil, do: :atom
  defp kind(_value), do: nil

  @doc """
  Whether `record` can satisfy the filter the plan was compiled from. `false` means it cannot; `true` means only that
  this module could not rule it out.

  ## Example

      iex> plan = {:compare, :>, :head, 3}
      iex> Ramal.Prefilter.possible?(plan, %{head: 2})
      false
      iex> Ramal.Prefilter.possible?(plan, %{head: 4})
      true
  """
  @spec possible?(t, map) :: boolean
  def possible?(plan, record), do: evaluate(plan, record) != false

  # `true` and `false` are exact answers; `:unknown` is "ask the runtime".
  defp evaluate(nil, _record), do: true
  defp evaluate(boolean, _record) when is_boolean(boolean), do: boolean
  defp evaluate(:unknown, _record), do: :unknown

  defp evaluate({:and, plans}, record), do: all(plans, record)
  defp evaluate({:or, plans}, record), do: any(plans, record)

  defp evaluate({:not, plan}, record) do
    case evaluate(plan, record) do
      :unknown -> :unknown
      boolean -> not boolean
    end
  end

  defp evaluate({:compare, operator, field, literal}, record) do
    case Map.get(record, field) do
      value when is_binary(value) and is_binary(literal) ->
        compare(operator, value, literal)

      value when is_integer(value) and is_integer(literal) ->
        compare(operator, value, literal)

      value when is_atom(value) and value != nil and is_atom(literal) ->
        compare(operator, value, literal)

      _other ->
        :unknown
    end
  end

  defp evaluate({:in, field, kind, members}, record) do
    value = Map.get(record, field)

    if kind(value) == kind, do: MapSet.member?(members, value), else: :unknown
  end

  defp evaluate({:nil?, field, is_nil?}, record) do
    case Map.get(record, field) do
      %struct{} when struct in [Ash.NotLoaded, Ash.ForbiddenField] -> :unknown
      value -> is_nil(value) == is_nil?
    end
  end

  defp compare(:==, left, right), do: left == right
  defp compare(:!=, left, right), do: left != right
  defp compare(:<, left, right), do: left < right
  defp compare(:>, left, right), do: left > right
  defp compare(:<=, left, right), do: left <= right
  defp compare(:>=, left, right), do: left >= right

  defp all(plans, record) do
    Enum.reduce_while(plans, true, fn plan, acc ->
      case evaluate(plan, record) do
        false -> {:halt, false}
        true -> {:cont, acc}
        :unknown -> {:cont, :unknown}
      end
    end)
  end

  defp any(plans, record) do
    Enum.reduce_while(plans, false, fn plan, acc ->
      case evaluate(plan, record) do
        true -> {:halt, true}
        false -> {:cont, acc}
        :unknown -> {:cont, :unknown}
      end
    end)
  end
end
