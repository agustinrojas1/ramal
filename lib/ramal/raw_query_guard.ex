defmodule Ramal.RawQueryGuard do
  @moduledoc false
  # The development and test guard behind `warn_raw_queries` of `Ramal.Supervisor` (issue #207).
  #
  # A branch holds the writes of Ash actions. A raw Ecto query (`Repo.all(from p in Paddock)`, `Repo.update_all`, a
  # join on a link table) never sees it: inside `Ramal.run/2` it reads the base data, and a validation or a number
  # computed from it is wrong without a sign. This guard attaches a `:telemetry` handler to the host repo's query event
  # (`repo.config()[:telemetry_prefix] ++ [:query]`) and reports a query when
  #
  #   * the calling process is inside `Ramal.run/2` (`Ramal.Current`, tasks started from it included), and
  #   * the query names the table of a branchable resource of the repo's app (`:ash_domains`), as its source or in a
  #     `FROM`, `JOIN`, `UPDATE` or `INTO` of its SQL, and
  #   * Ash did not issue it: the queries of Ash actions and of Ramal's own reads go through `AshPostgres.DataLayer`,
  #     which the stack of the calling process shows (`Ramal.Ash.data_layer_stack?/1`).
  #
  # The merge runs outside any branch, so its replay writes never match. Both modes are off by default.
  #
  # Each report emits `[:ramal, :raw_query, :detected]` (measurement `system_time`; metadata `branch_id`, `repo`,
  # `table`, `resource`, `query`, `call_site` and `stacktrace`). The mode decides what else happens:
  #
  #   * `true` - nothing else: the host attaches a handler that logs or warns as it likes (docs/limits.md).
  #   * `:raise` - `Ramal.run/2` returns `{:error, %Ramal.Error{reason: :raw_query}}` (and `Ramal.run!/2` raises it)
  #     once `fun` has returned, with the first query in `details`. It cannot fail the query itself: `:telemetry`
  #     detaches a handler that raises, and by then the query has run.
  #
  # The guard never logs: observability goes through the event, like the rest of the library. Without the option
  # nothing is attached.

  alias Ramal.{Current, Error, Telemetry}
  alias Ramal.Supervisor

  @handler_id __MODULE__
  # Frames of the stack that belong to the query machinery, not to the code that issued it.
  @machinery_prefixes ["Elixir.Ecto.", "Elixir.DBConnection.", "Elixir.Postgrex."]
  @machinery_modules [:telemetry, Process, Enum, DBConnection, Postgrex, __MODULE__]
  @depth 64

  @type mode :: true | :raise

  @doc false
  @spec attach(module) :: :ok
  def attach(repo) when is_atom(repo) do
    detach(repo)

    tables = branched_tables(Keyword.fetch!(repo.config(), :otp_app))
    event = event(repo)

    :ok =
      :telemetry.attach({@handler_id, repo}, event, &__MODULE__.handle_event/4, %{
        repo: repo,
        tables: tables
      })
  end

  @doc false
  @spec detach(module) :: :ok
  def detach(repo) do
    _ = :telemetry.detach({@handler_id, repo})
    :ok
  end

  @doc """
  The telemetry event the repo emits for each query.

  ## Example

      iex> Ramal.RawQueryGuard.event(Ramal.TestRepo)
      [:ramal, :test_repo, :query]
  """
  @spec event(module) :: [atom]
  def event(repo), do: Keyword.fetch!(repo.config(), :telemetry_prefix) ++ [:query]

  # The table of each branchable AshPostgres resource of the app's `:ash_domains`, as `%{table => resource}`. `mix
  # ramal.doctor` scans the project for the same ones.
  @doc false
  @spec branched_tables(atom) :: %{String.t() => module}
  def branched_tables(app) do
    for domain <- Application.get_env(app, :ash_domains, []),
        resource <- Ramal.Resource.branchable_resources(domain),
        Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer,
        table = AshPostgres.DataLayer.Info.table(resource),
        is_binary(table),
        into: %{},
        do: {table, resource}
  end

  @doc false
  @spec handle_event([atom], map, map, map) :: :ok
  def handle_event(_event, _measurements, metadata, %{repo: repo, tables: tables}) do
    with {:ok, %{raw_queries: mode}} when mode in [true, :raise] <- Supervisor.config(),
         branch_id when is_binary(branch_id) <- Current.id(),
         {table, resource} <- touched(tables, metadata),
         stacktrace = stacktrace(),
         false <- Ramal.Ash.data_layer_stack?(stacktrace) do
      report(mode, branch_id, repo, table, resource, metadata, stacktrace)
    else
      _skip -> :ok
    end
  end

  defp touched(tables, %{query: sql} = metadata) when is_binary(sql) do
    case metadata[:source] do
      source when is_binary(source) and is_map_key(tables, source) ->
        {source, tables[source]}

      _other ->
        Enum.find(tables, fn {table, _resource} -> sql_names_table?(sql, table) end)
    end
  end

  defp touched(_tables, _metadata), do: nil

  @doc """
  Whether `sql` reads or writes `table` in a `FROM`, `JOIN`, `UPDATE` or `INTO`, with or without a schema before it.

  A cheap substring test comes first, so a query that does not mention the table never compiles the pattern.

  ## Example

      iex> Ramal.RawQueryGuard.sql_names_table?(~s(UPDATE "paddocks" AS p0 SET "name" = $1), "paddocks")
      true
  """
  @spec sql_names_table?(String.t(), String.t()) :: boolean
  def sql_names_table?(sql, table) do
    quoted = ~s("#{table}")

    String.contains?(sql, quoted) and
      Regex.match?(~r/\b(?:FROM|JOIN|UPDATE|INTO)\s+(?:"[^"]+"\.)?#{Regex.escape(quoted)}/i, sql)
  end

  # A query runs under a dozen frames of Ecto, DBConnection and AshPostgres, so the default depth of 8 would never reach
  # the call site. OTP 26 and later take a depth for `current_stacktrace`; before that the only way is the node-wide
  # `backtrace_depth` flag, raised for the one call and put back.
  defp stacktrace do
    {:current_stacktrace, stacktrace} = Process.info(self(), {:current_stacktrace, @depth})
    stacktrace
  rescue
    ArgumentError ->
      previous = :erlang.system_flag(:backtrace_depth, @depth)

      try do
        {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
        stacktrace
      after
        :erlang.system_flag(:backtrace_depth, previous)
      end
  end

  defp report(mode, branch_id, repo, table, resource, metadata, stacktrace) do
    frames = Enum.reject(stacktrace, &machinery?(&1, repo))
    call_site = frames |> List.first() |> format_frame()

    detail = %{
      branch_id: branch_id,
      repo: repo,
      table: table,
      resource: resource,
      query: metadata.query,
      call_site: call_site,
      stacktrace: frames
    }

    Telemetry.raw_query(:detected, detail)

    if mode == :raise, do: Supervisor.record_raw_query(branch_id, detail)
    :ok
  end

  @doc false
  @spec error(map) :: Error.t()
  def error(detail) do
    Error.new(
      :raw_query,
      "a raw Ecto query on #{inspect(detail.table)} (#{inspect(detail.resource)}) ran inside branch " <>
        "#{inspect(detail.branch_id)} at #{detail.call_site}; it did not see the branch " <>
        "(warn_raw_queries: :raise, see docs/limits.md)",
      Map.take(detail, [:table, :resource, :call_site, :query])
    )
  end

  defp machinery?({module, _fun, _arity, _location}, repo) do
    name = Atom.to_string(module)

    module == repo or module in @machinery_modules or
      Enum.any?(@machinery_prefixes, &String.starts_with?(name, &1))
  end

  defp format_frame(nil), do: "unknown"
  defp format_frame(frame), do: Exception.format_stacktrace_entry(frame)
end
