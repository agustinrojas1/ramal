defmodule Ramal.Preparation.Fragments do
  @moduledoc false
  # A filter with a `fragment(...)` judged by the database on the branch's rows (ADR 0054).
  #
  # `Ash.Filter.Runtime` cannot evaluate a fragment: the SQL text is the database's to run, so the runtime gives
  # "unknown", which a filter treats as no match. A read in a branch judges the rows the branch created or changed
  # in Elixir, so `fragment("? > 80", capacity_head)` never matched them, and a row the branch changed that still
  # matched in the base vanished: wrong, and silently.
  #
  # The conjuncts of the filter that hold a fragment (directly, under an `exists`, or in an expression calculation) are
  # therefore sent to the database with the overlay's rows. The rows travel as an inline table, a `VALUES` list, that a
  # common table expression named like the resource's table shadows it for the one query:
  #
  #     WITH "paddocks" AS (SELECT v0."id" AS "id", ... FROM (VALUES ($1::uuid, ...)) AS v0 ("id", ...))
  #     SELECT p0."id" FROM "paddocks" AS p0 WHERE (? > 80)
  #
  # The query is the one Ash builds for the conjuncts, so the fragment, the calculations and the joins to resources the
  # branch did not change are the database's own. It reads only, and writes nothing, so a branch still reaches no table.
  # The rest of the filter is judged in Elixir as before, and a row must pass both, as the conjuncts of an `and` do.
  #
  # What the database cannot judge is refused with `:fragment_unsupported` instead of being answered wrongly:
  #
  #   * a resource on another data layer than AshPostgres, which has no SQL to run a fragment;
  #   * a table the CTE cannot shadow: a `schema`, a schema-per-tenant (`:context`) tenant, a polymorphic table;
  #   * a conjunct that reaches a resource the branch changed (`paddock.name == "x" and fragment(...)` is two conjuncts,
  #     but `fragment("? > ?", paddock.capacity_head, 80)` joins the base's paddocks), which the database would join as
  #     the base has it;
  #   * an attribute whose type has no SQL type for a parameter (`AshPostgres.SqlImplementation.parameterized_type/2`
  #     is `nil`).
  #
  # Confirmed against the locked deps: `Ash.Query.data_layer_query/2` and `Ash.DataLayer.run_query/2` are public and
  # return and run AshPostgres' Ecto query (Ash 3.37, `lib/ash/query/query.ex`, `lib/ash/data_layer/data_layer.ex`);
  # `AshPostgres.DataLayer.Info.table/1`, `schema/1` and `polymorphic?/1` (ash_postgres 2.15.1, `lib/data_layer/info.ex`);
  # `Ecto.Query.values/2` and `with_cte/3` (ecto 3.14, `lib/ecto/query.ex`, `lib/ecto/query/api.ex`); a CTE named like a
  # table is the name the later `FROM` resolves, as in the Postgres manual's "WITH Queries" (the CTE is not recursive,
  # so its own body does not see itself).

  alias Ramal.{Error, Resource}
  alias Ramal.Preparation.Related

  @doc """
  The conjuncts of `filter` that hold a fragment, as a filter (or `nil`), and the rest, as a filter (or `nil`).
  """
  @spec split(Ash.Filter.t() | nil) :: {Ash.Filter.t() | nil, Ash.Filter.t() | nil}
  def split(filter) do
    {fragments, rest} = filter |> Related.conjuncts() |> Enum.split_with(&Ramal.Ash.fragment?/1)
    {Related.filter_of(filter, fragments), Related.filter_of(filter, rest)}
  end

  @doc """
  The keys of the `records` that satisfy `filter` (the fragment conjuncts) by the database's judgement, or an error
  when the database cannot judge them.
  """
  @spec matching(Ash.Query.t(), [struct], Ash.Filter.t()) ::
          {:ok, MapSet.t()} | {:error, Error.t()}
  def matching(_query, [], _filter), do: {:ok, MapSet.new()}

  def matching(query, records, filter) do
    with :ok <- supported(query.resource),
         {:ok, rows} <- run(query, records, filter) do
      {:ok, MapSet.new(rows, Resource.key_fun(query.resource))}
    end
  end

  @doc """
  Refuses a read whose filter holds a fragment in a conjunct that reaches a resource the branch changed (`removed` is
  what `Ramal.Preparation.Related` takes out of the data-layer query). The database would join the base's rows for it,
  and the runtime that must judge it instead cannot run a fragment, so every row it checks would be dropped.
  """
  @spec check_removed(Ash.Query.t(), Ash.Filter.t() | nil) :: :ok | {:error, Error.t()}
  def check_removed(_query, nil), do: :ok

  def check_removed(query, removed) do
    if Ramal.Ash.fragment?(removed),
      do:
        refuse(
          query.resource,
          "the filter with the fragment reaches a resource the branch changed, which the database would join as the base has it"
        ),
      else: :ok
  end

  defp supported(resource) do
    cond do
      Ash.Resource.Info.data_layer(resource) != AshPostgres.DataLayer ->
        refuse(resource, "its data layer is not AshPostgres, so no database can run the fragment")

      not Code.ensure_loaded?(__MODULE__.Postgres) ->
        refuse(resource, "Ecto is not available")

      (why = shadowable(resource)) != :ok ->
        refuse(resource, why)

      true ->
        :ok
    end
  end

  # The CTE replaces the table by its unqualified name, so a table in a schema, a tenant that is a schema and a
  # polymorphic table cannot be shadowed.
  defp shadowable(resource) do
    cond do
      AshPostgres.DataLayer.Info.schema(resource) not in [nil, "public"] ->
        "its table is in a schema"

      Ash.Resource.Info.multitenancy_strategy(resource) == :context ->
        "its tenant is a schema"

      AshPostgres.DataLayer.Info.polymorphic?(resource) ->
        "its table is polymorphic"

      true ->
        :ok
    end
  end

  defp refuse(resource, why) do
    {:error,
     Error.new(
       :fragment_unsupported,
       "a read of #{inspect(resource)} in a branch filters with a fragment, which only the database can evaluate, and " <>
         "the branch's rows cannot be given to it: #{why}. Filter with an expression the runtime can evaluate, or read outside the branch.",
       %{resource: resource}
     )}
  end

  defp run(query, records, filter) do
    if Code.ensure_loaded?(__MODULE__.Postgres) do
      __MODULE__.Postgres.run(query, records, filter)
    end
  end
end
