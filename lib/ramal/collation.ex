defmodule Ramal.Collation do
  @moduledoc false
  # Text sorted in Elixir the way the database sorts it (ADR 0045, which supersedes ADR 0024).
  #
  # A read in a branch whose resource the overlay touches is sorted in memory, where strings compare as bytes. Postgres
  # orders a text column by its collation (`en_US.UTF-8` puts `apple` before `Banana`), so the branch and the merged
  # database disagreed. No Elixir comparator reproduces a collation (glibc or ICU, per database or per column), so the
  # database is asked: the distinct values of a sort key go to Postgres in one query that returns each value's
  # `dense_rank()` under the column's collation, and the in-memory sort orders by the rank. Values equal under the
  # collation (`citext`'s `Apple` and `apple`) share a rank, so the next sort key breaks the tie, as in SQL.
  #
  #   * The collation is the column's: `pg_attribute.attcollation` joined to `pg_collation`, read once per table and
  #     column and kept in `:persistent_term`. It is not kept for a resource whose tenants are schemas (`strategy
  #     :context`), where the same column can differ from one tenant to the next. A column changed with `ALTER TABLE ...
  #     COLLATE` is seen after a restart.
  #   * A column of collation `C`, `POSIX` or `ucs_basic` is in byte order already, so it is not queried. A `citext`
  #     column orders by `lower(v)`, as the type does. A sort key that is not a column (an expression calculation other
  #     than a plain reference, an aggregate of one) is ranked by the database's default collation.
  #   * Only an AshPostgres resource is asked; any other data layer, and any key that is not text, keeps the runtime
  #     sort of Ash (`Ash.Actions.Sort.runtime_sort/3`), which is also what orders everything between two text keys.
  #   * The query is a read: Ramal still writes nothing to the database from a branch.
  #
  # `sort/3` sorts one key at a time, the last key first, as a stable sort does. That gives the order of
  # `runtime_sort/3` (a lexicographic sort on the keys, ties kept in the order the rows came in, `nil`s placed by the
  # direction) with the text keys replaced by their ranks.
  #
  # Confirmed against the locked deps:
  #
  #   * `AshPostgres.DataLayer.Info.repo/2`, `table/1` and `schema/1` (ash_postgres 2.15.1, `lib/data_layer/info.ex`); the
  #     repo may be a function of the resource and the type, so it is asked for `:read`.
  #   * `repo.query/2` returns `{:ok, %{rows: rows}}` or `{:error, exception}` (ecto_sql 3.14,
  #     `Ecto.Adapters.SQL`, which injects `query/3` into the repo); it runs on the connection the calling process
  #     holds, so a read inside a transaction or a sandbox uses it, and it honours a dynamic repo.
  #   * `Ash.ToTenant.to_tenant/2` is the schema AshPostgres sets as the query prefix for a `:context` tenant
  #     (`lib/data_layer.ex`, `Ecto.Query.put_query_prefix(query, to_string(tenant))`, ash_postgres 2.15.1).
  #   * `Ash.Type.NewType.subtype_of/1` and `new_type?/1`, `Ash.CiString.value/1`, and the sort entries of a hydrated
  #     query: `{field, direction}` for an attribute, `{%Ash.Query.Calculation{}, direction}` for a calculation, with
  #     its expression wrapped in `Ash.Query.Function.Type`, and `{%Ash.Query.Aggregate{}, direction}` (Ash 3.37,
  #     `lib/ash/actions/sort.ex`, which also defines the directions and where it reads a loaded value).
  #   * Postgres: `pg_attribute.attcollation` is the column's collation (100, named `default`, when none is set),
  #     `citext` compares `lower(a) < lower(b)` under the default collation (`citext_cmp`), `to_regclass/1` resolves a
  #     quoted name against the search path, and `unnest` of a text array with `dense_rank() OVER (ORDER BY ...)` is
  #     plain SQL.

  alias Ash.Actions.Sort
  alias Ash.Resource.Info
  alias Ash.Type.Atom, as: AtomType
  alias Ash.Type.CiString
  alias Ash.Type.NewType
  alias Ash.Type.String, as: StringType
  alias AshPostgres.DataLayer.Info, as: PgInfo
  alias Ramal.Error

  @byte_order ["C", "POSIX", "ucs_basic"]

  @typedoc "How the database orders a column: the repo to ask, the quoted collation (or `nil` for the default) and `citext`."
  @type collation :: %{
          repo: module,
          collate: String.t() | nil,
          lower?: boolean
        }

  @doc """
  Sorts `rows` by `sort` as `Ash.Actions.Sort.runtime_sort/3` does, except that a text key is ordered by the rank the
  database gives its values. `opts` are the options of `runtime_sort/3` (`:resource` and `:domain` are needed,
  `:lazy?` and `:rename_calcs?` are passed on) and `:tenant`, which the catalog lookup of a schema-per-tenant resource
  needs.
  """
  @spec sort([struct], [{term, atom}], keyword) :: {:ok, [struct]} | {:error, Error.t()}
  def sort(rows, sort, opts) when length(rows) < 2 or sort in [nil, []],
    do: {:ok, Sort.runtime_sort(rows, sort || [], runtime_opts(opts))}

  def sort(rows, sort, opts) do
    with {:ok, plans} <- plan(Keyword.fetch!(opts, :resource), sort, opts[:tenant]) do
      if Enum.all?(plans, &(&1 == :runtime)) do
        {:ok, Sort.runtime_sort(rows, sort, runtime_opts(opts))}
      else
        sort |> Enum.zip(plans) |> steps() |> Enum.reverse() |> run_steps(rows, opts)
      end
    end
  end

  defp run_steps(steps, rows, opts) do
    Enum.reduce_while(steps, {:ok, rows}, fn step, {:ok, rows} ->
      case apply_step(step, rows, opts) do
        {:ok, rows} -> {:cont, {:ok, rows}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  `values` of `field` of `resource` in ascending order of the database's collation, for the `:min` and `:max` of an
  aggregate; `:runtime` when the field is not text the database orders (the caller then sorts them as it did before).
  """
  @spec order_values(module, atom, [term], term) :: {:ok, [term]} | :runtime | {:error, Error.t()}
  def order_values(_resource, _field, values, _tenant) when length(values) < 2, do: :runtime

  def order_values(resource, field, values, tenant) do
    with {:ok, [plan]} <- plan(resource, [{field, :asc}], tenant),
         {:text, collation} <- plan,
         {:ok, texts} <- texts(values),
         {:ok, ranks} <- ranks(collation, texts) do
      {:ok,
       Enum.sort_by(Enum.zip(values, texts), fn {_value, text} -> ranks[text] end)
       |> Enum.map(&elem(&1, 0))}
    else
      :runtime -> :runtime
      :unsupported -> :runtime
      {:error, _} = error -> error
    end
  end

  # ---- which keys are text the database orders ----

  defp plan(resource, sort, tenant) do
    Enum.reduce_while(sort, {:ok, []}, fn {key, _direction}, {:ok, plans} ->
      case plan_key(resource, key, tenant) do
        {:ok, plan} -> {:cont, {:ok, [plan | plans]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      error -> error
    end
  end

  defp plan_key(resource, key, tenant) do
    case source(resource, key) do
      {:column, column_resource, attribute} ->
        column_plan(column_resource, attribute, tenant)

      :text ->
        default_plan(resource)

      :other ->
        {:ok, :runtime}
    end
  end

  defp column_plan(resource, attribute, tenant) do
    if postgres?(resource) do
      with {:ok, collation} <- lookup(resource, attribute, tenant), do: {:ok, as_plan(collation)}
    else
      {:ok, :runtime}
    end
  end

  defp default_plan(resource) do
    if postgres?(resource),
      do: {:ok, {:text, %{repo: PgInfo.repo(resource, :read), collate: nil, lower?: false}}},
      else: {:ok, :runtime}
  end

  defp as_plan(:bytes), do: :runtime
  defp as_plan(%{} = collation), do: {:text, collation}

  defp postgres?(resource) do
    Info.data_layer(resource) == AshPostgres.DataLayer and PgInfo.table(resource) != nil
  end

  # The column a sort key reads, when it is one: `{:column, resource, attribute}`; `:text` for a key that is text and
  # not a column; `:other` for everything else.
  defp source(resource, key) when is_atom(key) do
    case Info.attribute(resource, key) do
      %{type: type} = attribute ->
        if text_type?(type), do: {:column, resource, attribute}, else: :other

      nil ->
        :other
    end
  end

  defp source(resource, %Ash.Query.Calculation{type: type} = calculation) do
    if text_type?(type) do
      case referenced_column(resource, calculation) do
        {:ok, column_resource, attribute} -> {:column, column_resource, attribute}
        :error -> :text
      end
    else
      :other
    end
  end

  defp source(resource, %Ash.Query.Aggregate{kind: kind, field: field} = aggregate)
       when kind in [:first, :min, :max] and is_atom(field) and not is_nil(field) do
    with %{} = destination <- aggregate_destination(resource, aggregate.relationship_path),
         %{type: type} = attribute <- Info.attribute(destination, field),
         true <- text_type?(type) do
      {:column, destination, attribute}
    else
      _ -> :other
    end
  end

  defp source(_resource, _key), do: :other

  # A calculation that is just a reference to an attribute (`paddock.name`, possibly under a type cast) is that column.
  # Any other expression has no column of its own.
  defp referenced_column(resource, %{module: module, opts: opts, context: context}) do
    with true <- Ash.Resource.Calculation.has_expression?(module),
         expression = Ash.Resource.Calculation.expression(module, opts, context),
         {:ok, hydrated} <-
           Ash.Filter.hydrate_refs(expression, %{
             resource: resource,
             relationship_path: [],
             public?: false
           }),
         %Ash.Query.Ref{attribute: %{name: name}, resource: column_resource} <- unwrap(hydrated),
         %{type: type} = attribute <- Info.attribute(column_resource, name),
         true <- text_type?(type) do
      {:ok, column_resource, attribute}
    else
      _ -> :error
    end
  end

  defp unwrap(%Ash.Query.Function.Type{arguments: [inner | _]}), do: unwrap(inner)
  defp unwrap(other), do: other

  defp aggregate_destination(resource, path) do
    Enum.reduce_while(path, resource, fn name, source ->
      case Info.relationship(source, name) do
        nil -> {:halt, nil}
        relationship -> {:cont, relationship.destination}
      end
    end)
  end

  defp text_type?(type) do
    type = Ash.Type.get_type(type)
    type = if NewType.new_type?(type), do: NewType.subtype_of(type), else: type
    type in [StringType, CiString, AtomType]
  end

  # ---- the column's collation ----

  # `{:ok, :bytes}` when the column is in byte order, or the `t:collation/0` to rank by.
  defp lookup(resource, attribute, tenant) do
    repo = PgInfo.repo(resource, :read)
    table = PgInfo.table(resource)
    column = to_string(attribute.source || attribute.name)
    per_tenant? = Info.multitenancy_strategy(resource) == :context

    schema =
      if per_tenant? and tenant != nil,
        do: to_string(Ash.ToTenant.to_tenant(tenant, resource)),
        else: PgInfo.schema(resource)

    if per_tenant? do
      catalog(repo, schema, table, column)
    else
      cached({__MODULE__, repo, schema, table, column}, fn ->
        catalog(repo, schema, table, column)
      end)
    end
  end

  defp cached(key, fun) do
    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, collation} <- fun.() do
          :persistent_term.put(key, collation)
          {:ok, collation}
        end

      collation ->
        {:ok, collation}
    end
  end

  @catalog """
  SELECT t.typname, c.collname, n.nspname
  FROM pg_attribute a
  JOIN pg_type t ON t.oid = a.atttypid
  LEFT JOIN pg_collation c ON c.oid = a.attcollation
  LEFT JOIN pg_namespace n ON n.oid = c.collnamespace
  WHERE a.attrelid = to_regclass($1::text) AND a.attname = $2::text AND NOT a.attisdropped
  """

  defp catalog(repo, schema, table, column) do
    relation = Enum.map_join(Enum.reject([schema, table], &is_nil/1), ".", &quote_ident/1)

    case repo.query(@catalog, [relation, column]) do
      {:ok, %{rows: [[type, collation, namespace]]}} ->
        {:ok, collation(repo, type, collation, namespace)}

      # The column is not where the resource says (a table the migrations have not created, a schema that does not
      # exist yet): the default collation is the likeliest.
      {:ok, %{rows: []}} ->
        {:ok, %{repo: repo, collate: nil, lower?: false}}

      {:error, exception} ->
        {:error, failed("read the collation of #{relation}.#{column}", exception)}
    end
  end

  defp collation(repo, type, name, namespace) do
    lower? = type == "citext"

    cond do
      name in @byte_order and not lower? ->
        :bytes

      name in [nil, "default"] ->
        %{repo: repo, collate: nil, lower?: lower?}

      true ->
        %{repo: repo, collate: quote_ident(namespace) <> "." <> quote_ident(name), lower?: lower?}
    end
  end

  defp quote_ident(name), do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|

  # ---- ranks ----

  # One query for the distinct values of a key. Values equal under the collation come back with the same rank.
  defp ranks(_collation, []), do: {:ok, %{}}

  defp ranks(%{repo: repo, collate: collate, lower?: lower?}, texts) do
    value = if collate, do: "t.v COLLATE #{collate}", else: "t.v"
    order = if lower?, do: "lower(#{value})", else: value

    sql =
      "SELECT t.v, dense_rank() OVER (ORDER BY #{order}) FROM unnest($1::text[]) AS t(v)"

    case repo.query(sql, [Enum.uniq(texts)]) do
      {:ok, %{rows: rows}} -> {:ok, Map.new(rows, fn [text, rank] -> {text, rank} end)}
      {:error, exception} -> {:error, failed("rank #{length(texts)} text values", exception)}
    end
  end

  defp failed(what, exception) do
    Error.new(
      :collation_failed,
      "could not #{what} to sort text the way the database does: #{Exception.message(exception)}",
      %{error: exception}
    )
  end

  # ---- the sort ----

  # Consecutive keys that Ash sorts stay one `runtime_sort/3` call; each text key is a step of its own.
  defp steps(entries) do
    entries
    |> Enum.chunk_by(fn {_entry, plan} -> plan == :runtime end)
    |> Enum.flat_map(fn
      [{_entry, :runtime} | _] = chunk ->
        [{:runtime, Enum.map(chunk, &elem(&1, 0))}]

      chunk ->
        for {{key, direction}, {:text, collation}} <- chunk,
            do: {:text, key, direction, collation}
    end)
  end

  defp apply_step({:runtime, keys}, rows, opts),
    do: {:ok, Sort.runtime_sort(rows, keys, runtime_opts(opts))}

  defp apply_step({:text, key, direction, collation}, rows, opts) do
    with {:ok, loaded} <- load(rows, key, opts),
         {:ok, texts} <- texts(Enum.map(loaded, &value(&1, key))),
         {:ok, ranks} <- ranks(collation, Enum.reject(texts, &is_nil/1)) do
      sorted =
        rows
        |> Enum.zip(texts)
        |> Enum.sort_by(fn {_row, text} -> text && Map.fetch!(ranks, text) end, sorter(direction))
        |> Enum.map(&elem(&1, 0))

      {:ok, sorted}
    else
      # A value that is not text (a field the query did not select, say): leave the key to Ash.
      :unsupported -> {:ok, Sort.runtime_sort(rows, [{key, direction}], runtime_opts(opts))}
      {:error, _} = error -> error
    end
  end

  # What `Ash.Actions.Sort` does before it reads a calculation or an aggregate (`load_field/4`): the value is loaded
  # onto the record, reusing the ones it has. The rows that are sorted stay as they came; only their values are read.
  defp load(rows, key, _opts) when is_atom(key), do: {:ok, rows}

  defp load(rows, key, opts) do
    resource = Keyword.fetch!(opts, :resource)

    query =
      resource
      |> Ash.Query.select([])
      |> Ash.Query.load(key)
      |> Ash.Query.set_context(%{private: %{internal?: true}})

    case opts[:domain] do
      nil ->
        {:ok, rows}

      domain ->
        Ash.load(rows, query,
          domain: domain,
          tenant: opts[:tenant],
          reuse_values?: true,
          authorize?: false,
          lazy?: opts[:lazy?] || false
        )
    end
  end

  # `resolve_field/2` of `Ash.Actions.Sort`.
  defp value(record, %Ash.Query.Calculation{load: load}) when load != nil,
    do: Map.get(record, load)

  defp value(record, %Ash.Query.Calculation{name: name}), do: Map.get(record.calculations, name)
  defp value(record, %Ash.Query.Aggregate{load: load}) when load != nil, do: Map.get(record, load)
  defp value(record, %Ash.Query.Aggregate{name: name}), do: Map.get(record.aggregates, name)

  defp value(record, field) do
    case Map.get(record, field) do
      %Ash.ForbiddenField{} -> nil
      other -> other
    end
  end

  defp texts(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, texts} ->
      case text(value) do
        :error -> {:halt, :unsupported}
        text -> {:cont, {:ok, [text | texts]}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      :unsupported -> :unsupported
    end
  end

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(%Ash.CiString{} = value), do: Ash.CiString.value(value)
  defp text(value) when is_atom(value) and value not in [true, false], do: Atom.to_string(value)
  defp text(_value), do: :error

  # The placement of `nil`s and the direction of `to_sort_by_fun/1` in `Ash.Actions.Sort`, over ranks: `:asc` puts
  # them last and `:desc` first, as Postgres does. Equal ranks keep their order.
  defp sorter(direction) do
    {order, nils} = placement(direction)

    fn
      nil, nil -> true
      nil, _rank -> nils == :first
      _rank, nil -> nils == :last
      a, b -> compare(order, a, b)
    end
  end

  defp compare(:asc, a, b), do: a <= b
  defp compare(:desc, a, b), do: a >= b

  defp placement(:asc), do: {:asc, :last}
  defp placement(:asc_nils_last), do: {:asc, :last}
  defp placement(:asc_nils_first), do: {:asc, :first}
  defp placement(:desc), do: {:desc, :first}
  defp placement(:desc_nils_first), do: {:desc, :first}
  defp placement(:desc_nils_last), do: {:desc, :last}

  defp runtime_opts(opts), do: Keyword.take(opts, [:resource, :domain, :lazy?, :rename_calcs?])
end
