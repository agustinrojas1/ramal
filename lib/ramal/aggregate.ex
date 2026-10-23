defmodule Ramal.Aggregate do
  @moduledoc """
  Aggregates for `Ramal.aggregate/4`: a pure computation over a list of records, and the delta path that uses it.

  The aggregates Ash hands to the data layer never see a branch's overlay. `Ramal.aggregate/4` therefore answers in
  one of two ways:

    * **delta** (the default). Let K be the primary keys in the branch's overlay for the resource. The database
      aggregates every matching row except K (`delta/5`, which is `Ash.count/2`, `Ash.sum/3` and the like with a
      key filter added). The branch then reads only the K rows through the patched path, which gives exactly the
      branch's version of them, filtered by the whole query. `combine/5` joins the two. The cost grows with the size of
      the overlay, not with the size of the table. It does not apply when the query has a limit, an offset or a
      `distinct`, because the aggregate then depends on the order of rows the delta does not have.
    * **read** (`compute/4`). Read every matching row through the patched path and aggregate in Elixir. Exact for any
      query, and as expensive as the read.

  The kinds follow Ash's: `:count` (rows), `:exists`, `:sum`, `:min`, `:max`, `:avg`, `:first` and `:list`. As in SQL,
  `nil` values are skipped, and `:sum`, `:min`, `:max` and `:avg` of no values are `nil`. `:first` and `:list` read the
  records in the order given, so the caller sorts them first (the aggregate's own sort, or the query's); `:first` is the
  first value, `:list` every value, both skipping `nil` unless `include_nil?: true`, and `uniq?: true` keeps the first of
  each value in a `:list` and counts distinct non-nil values in a `:count`. A `:custom` aggregate is a data-layer module
  that produces SQL, so it is not here. `:sum` of decimals is a `Decimal`, `:avg` is a
  float (Ash types it as `:float`, `lib/ash/query/aggregate.ex`). `:min` and `:max` order values the way a runtime sort
  does (the runtime sort in Ash.Actions.Sort), so dates and decimals compare by their type. Strings of an AshPostgres
  resource compare by the collation of the column, which Ramal.Collation (an internal module) asks the database for (ADR 0045); the
  function then reads from the database and raises `Ramal.Error` with reason `:collation_failed` if that fails.

  Confirmed against Ash 3.37 for the delta path: the aggregate action (`lib/ash/actions/aggregate.ex`) builds its query with
  `Ash.Query.for_read/4`, so the action's policies and preparations apply, but it does not run the `before_action` and
  `after_action` hooks that `Ramal.Preparation` installs. The database part is therefore never patched, which is what
  the delta needs. The rows it aggregates are not fingerprinted either, so they do not join the merge staleness check
  (ADR 0013).

  ## Example

      iex> records = [%{head: 30}, %{head: nil}, %{head: 12}]
      iex> Ramal.Aggregate.compute(:sum, :head, records, Ramal.Test.Farm.Herd)
      42
      iex> Ramal.Aggregate.compute(:count, nil, records, Ramal.Test.Farm.Herd)
      3
      iex> Ramal.Aggregate.combine(:sum, :head, Ramal.Test.Farm.Herd, 100, [%{head: 30}, %{head: nil}])
      130
  """

  require Ash.Expr

  alias Ash.Resource.Info
  alias Ramal.{Collation, Resource}

  @kinds [:count, :exists, :sum, :min, :max, :avg, :first, :list]

  @typedoc "An aggregate kind."
  @type kind :: :count | :exists | :sum | :min | :max | :avg | :first | :list

  @doc """
  The kinds `compute/4` knows.

  ## Example

      iex> Ramal.Aggregate.kinds()
      [:count, :exists, :sum, :min, :max, :avg, :first, :list]
  """
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc """
  Computes `kind` over `records`, which are rows of `resource`. `field` is the attribute to aggregate; `:count` and
  `:exists` ignore it unless `:count` has one to count. Raises `ArgumentError` for an unknown kind, or for a field that
  is not an attribute of `resource` when the kind is `:sum`, `:min`, `:max` or `:avg`. `:first`, `:list` and a `:count`
  of a field take whatever the records hold under `field`, so a calculation loaded onto them works too.

  `opts` are `:uniq?` and `:include_nil?`, as on an Ash aggregate (both default to `false`), and `:tenant`, which the
  collation of a string column in a schema-per-tenant resource needs for `:min` and `:max`.

  ## Example

      iex> Ramal.Aggregate.compute(:max, :head, [%{head: 30}, %{head: 12}], Ramal.Test.Farm.Herd)
      30
      iex> Ramal.Aggregate.compute(:avg, :head, [%{head: 30}, %{head: 12}], Ramal.Test.Farm.Herd)
      21.0
      iex> Ramal.Aggregate.compute(:exists, nil, [], Ramal.Test.Farm.Herd)
      false
      iex> Ramal.Aggregate.compute(:list, :head, [%{head: 30}, %{head: 30}, %{head: nil}], Ramal.Test.Farm.Herd, uniq?: true)
      [30]
      iex> Ramal.Aggregate.compute(:first, :head, [%{head: nil}, %{head: 12}], Ramal.Test.Farm.Herd)
      12
  """
  @spec compute(kind, atom | nil, [map], module, keyword) :: term
  def compute(kind, field, records, resource, opts \\ [])

  def compute(:count, field, records, _resource, opts) do
    if field != nil and opts[:uniq?] do
      records |> present(field) |> uniq() |> length()
    else
      length(records)
    end
  end

  def compute(:exists, _field, records, _resource, _opts), do: records != []

  def compute(:first, field, records, _resource, opts) do
    if opts[:include_nil?] do
      records |> List.first() |> then(&if(&1, do: Map.fetch!(&1, field)))
    else
      records |> present(field) |> List.first()
    end
  end

  def compute(:list, field, records, _resource, opts) do
    values =
      if opts[:include_nil?],
        do: Enum.map(records, &Map.fetch!(&1, field)),
        else: present(records, field)

    if opts[:uniq?], do: uniq(values), else: values
  end

  def compute(kind, field, records, resource, opts) when kind in [:sum, :min, :max, :avg] do
    validate!(kind, field, resource)

    values =
      records
      |> Enum.map(&Map.fetch!(&1, field))
      |> Enum.reject(&is_nil/1)

    reduce(kind, field, values, resource, opts[:tenant])
  end

  def compute(kind, field, _records, resource, _opts), do: validate!(kind, field, resource)

  defp present(records, field),
    do: records |> Enum.map(&Map.fetch!(&1, field)) |> Enum.reject(&is_nil/1)

  # Keeps the first of each value, as `array_agg(DISTINCT ...)` and the ETS data layer do. Postgres treats 1.0 and 1.00
  # as one numeric, so decimals are compared normalized.
  defp uniq(values),
    do: Enum.uniq_by(values, &if(is_struct(&1, Decimal), do: Decimal.normalize(&1), else: &1))

  @doc """
  Joins the database's answer for the rows outside the overlay with the branch's rows inside it. `base` is the
  database's value for `kind`: an integer for `:count`, a boolean for `:exists`, the value or `nil` for `:sum`, `:min`
  and `:max`, and `{sum, non_nil_count}` for `:avg`. `rows` are the branch's version of the overlaid rows that match the
  query. `opts` are those of `compute/5`.

  ## Example

      iex> Ramal.Aggregate.combine(:count, nil, Ramal.Test.Farm.Herd, 10, [%{}, %{}])
      12
      iex> Ramal.Aggregate.combine(:max, :head, Ramal.Test.Farm.Herd, 30, [%{head: 35}])
      35
      iex> Ramal.Aggregate.combine(:avg, :head, Ramal.Test.Farm.Herd, {60, 2}, [%{head: 30}])
      30.0
      iex> Ramal.Aggregate.combine(:sum, :head, Ramal.Test.Farm.Herd, nil, [])
      nil
  """
  @spec combine(kind, atom | nil, module, term, [map], keyword) :: term
  def combine(kind, field, resource, base, rows, opts \\ [])
  def combine(:count, _field, _resource, base, rows, _opts), do: base + length(rows)
  def combine(:exists, _field, _resource, base, rows, _opts), do: base or rows != []

  def combine(kind, field, resource, base, rows, opts) when kind in [:sum, :min, :max] do
    validate!(kind, field, resource)
    values = base_values(base) ++ values(rows, field)
    reduce(kind, field, values, resource, opts[:tenant])
  end

  def combine(:avg, field, resource, {base_sum, base_count}, rows, _opts) do
    validate!(:avg, field, resource)
    branch = values(rows, field)

    case base_count + length(branch) do
      0 -> nil
      count -> mean(sum(base_values(base_sum) ++ branch), count)
    end
  end

  @doc """
  The delta path of `Ramal.aggregate/4`: `kind` over `query` for a branch whose overlay holds `keys` (the primary keys
  of the overlaid rows of the resource). Returns `{:ok, value}` or the error Ash returned. `opts` are the read options
  (`:actor`, `:authorize?`, `:tenant`, `:domain`).

  Call it only inside `Ramal.run/2`, and only when `applies?/2` is true.
  """
  @spec delta(Ash.Query.t(), kind, atom | nil, keyword, [term]) :: {:ok, term} | {:error, term}
  def delta(query, kind, field, opts, keys) do
    resource = query.resource

    with {:ok, base} <- database(exclude(query, keys), kind, field, opts),
         {:ok, rows} <- Resource.read_all(restrict(query, keys), opts) do
      {:ok, combine(kind, field, resource, base, rows, tenant: opts[:tenant] || query.tenant)}
    end
  end

  # Composite keys are matched with one disjunct per key, so a large overlay of them is cheaper to read than to filter.
  @max_composite_keys 500

  @doc """
  Whether the delta path is valid for `query` with `key_count` overlaid rows. A limit, an offset or a `distinct` make the
  aggregate depend on which rows come first, which the delta does not know.

  ## Example

      iex> Ramal.Aggregate.applies?(Ash.Query.new(Ramal.Test.Farm.Herd), 3)
      true
      iex> Ramal.Aggregate.applies?(Ash.Query.limit(Ramal.Test.Farm.Herd, 2), 3)
      false
  """
  @spec applies?(Ash.Query.t(), non_neg_integer) :: boolean
  def applies?(query, key_count) do
    is_nil(query.limit) and query.offset in [nil, 0] and query.distinct in [nil, []] and
      (length(Info.primary_key(query.resource)) == 1 or key_count <= @max_composite_keys)
  end

  # The database's answer for the rows outside the overlay, in the shape combine/5 takes.
  defp database(query, :count, _field, opts), do: Ash.count(query, opts)
  defp database(query, :exists, _field, opts), do: Ash.exists(query, opts)

  defp database(query, :avg, field, opts) do
    with {:ok, %{sum: sum, count: count}} <-
           Ash.aggregate(
             query,
             [{:sum, :sum, field: field}, {:count, :count, field: field}],
             opts
           ) do
      {:ok, {sum, count}}
    end
  end

  defp database(query, kind, field, opts), do: apply(Ash, kind, [query, field, opts])

  defp exclude(query, keys) do
    Ramal.Ash.do_filter(query, Ash.Expr.expr(not (^key_expression(query.resource, keys))))
  end

  defp restrict(query, keys), do: Ramal.Ash.do_filter(query, key_expression(query.resource, keys))

  defp key_expression(resource, keys) do
    case Info.primary_key(resource) do
      [field] -> Ash.Expr.expr(^Ash.Expr.ref(field) in ^keys)
      fields -> Enum.reduce(keys, false, &Ash.Expr.expr(^&2 or ^composite_key(fields, &1)))
    end
  end

  defp composite_key(fields, key) do
    fields
    |> Enum.zip(Tuple.to_list(key))
    |> Enum.reduce(true, fn {field, value}, all ->
      Ash.Expr.expr(^all and ^Ash.Expr.ref(field) == ^value)
    end)
  end

  defp values(rows, field), do: rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.reject(&is_nil/1)
  defp base_values(nil), do: []
  defp base_values(value), do: [value]

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

  def validate!(kind, field, resource) when kind in [:sum, :min, :max, :avg, :first, :list] do
    unless is_atom(field) and not is_nil(field) and Info.attribute(resource, field) do
      raise ArgumentError,
            "#{inspect(field)} is not an attribute of #{inspect(resource)}; aggregates here cover attributes only"
    end

    :ok
  end

  def validate!(kind, _field, _resource) do
    raise ArgumentError, "unknown aggregate kind #{inspect(kind)}; use one of #{inspect(@kinds)}"
  end

  defp reduce(_kind, _field, [], _resource, _tenant), do: nil
  defp reduce(:sum, _field, values, _resource, _tenant), do: sum(values)
  defp reduce(:avg, _field, values, _resource, _tenant), do: average(values)

  defp reduce(kind, field, values, resource, tenant) do
    sorted =
      case Collation.order_values(resource, field, values, tenant) do
        {:ok, sorted} -> sorted
        :runtime -> runtime_sorted(field, values, resource)
        {:error, error} -> raise error
      end

    if kind == :min, do: List.first(sorted), else: List.last(sorted)
  end

  # runtime_sort loads calculations onto records, so it needs real resource structs and not plain maps.
  defp runtime_sorted(field, values, resource) do
    values
    |> Enum.map(&struct(resource, [{field, &1}]))
    |> Ramal.Ash.runtime_sort([{field, :asc}], resource: resource, domain: Info.domain(resource))
    |> Enum.map(&Map.fetch!(&1, field))
  end

  defp sum(values) do
    if Enum.any?(values, &is_struct(&1, Decimal)) do
      values |> Enum.map(&to_decimal/1) |> Enum.reduce(&Decimal.add/2)
    else
      Enum.sum(values)
    end
  end

  defp average(values), do: mean(sum(values), length(values))

  defp mean(total, count) do
    total = if is_struct(total, Decimal), do: Decimal.to_float(total), else: total
    total / count
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
end
