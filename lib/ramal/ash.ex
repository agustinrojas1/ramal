defmodule Ramal.Ash do
  @tested_ash "~> 3.36.0 or ~> 3.37.0"
  @tested_ash_postgres "~> 2.15.0"

  alias Ash.Actions.Read
  alias Ash.Actions.Read.Relationships
  alias Ash.Actions.Sort
  alias Ash.Filter.Runtime

  @moduledoc """
  Ramal's contract with Ash: the versions of Ash and AshPostgres it is tested with, and every Ash internal it relies on.

  Ramal reaches into Ash where the public API does not cover what a branch needs, so a new Ash release can break a
  branch without a compile error. This module states the versions the suite passes on. `Ramal.Supervisor` compares them
  with the host's versions at boot and logs a warning when they differ; it never refuses to start.

  ## The tested range

  Ash `#{@tested_ash}`, AshPostgres `#{@tested_ash_postgres}`. The CI job `ash-matrix` runs the suite on Ash 3.36, 3.37,
  the newest 3.x and Ash's `main` branch, each resolving the newest versions its requirement allows. The range is widened
  only when the newest-3.x leg is green on a new minor, so every version in it has passed the suite. A version outside it
  may still work, and may also break a branch silently.

  ## Ash internals Ramal relies on

  Ramal hooks into Ash above the data layer, and some of what it needs there is internal to Ash or undocumented. Each
  assumption has a tripwire, a test in `test/ramal/ash_contract_test.exs` named `"assumption: ..."` that checks it
  against Ash alone, so a change in Ash fails CI with the assumption's name instead of writing a wrong row.

    * A result set with `Ash.Changeset.set_result/2` in the last `before_action` hook skips the data layer on create,
      update and destroy (`Ramal.Capture`).
    * A bulk action runs a changeset with an `around_action` hook one record at a time (`Ramal.Capture`).
    * `change/3` sees an upsert in `context.private` (`upsert?`, `upsert_identity`, `upsert_fields`,
      `upsert_condition`), and a resource's global changes run after the action's own (`Ramal.Capture`).
    * A change that answers `{:not_atomic, _}` from `atomic/3` sends an update or destroy with `require_atomic? false`
      down the path that runs `change/3` and the hooks (`Ramal.Capture`, the resource transformer).
    * `Ash.Query.set_result/2` in the last `before_action` hook of a read and `full_count` in its context become the
      page and its count (`Ramal.Preparation`).
    * A relationship load paged per source carries `context.data_layer.lateral_join_source` as `{records, path}` and
      tags rows with `__lateral_join_source__` (`Ramal.Preparation` and its lateral and many-to-many readers).
    * `Ash.load/3` reselects a record's source attribute without running read preparations, which is why
      `Ramal.load/3` exists.
    * An atomic bulk update of a query with a `before_action` hook is refused, and a streamed one runs the query's
      `before_transaction` hook and the `before_action` hooks it adds (`Ramal.Preparation`).
    * The context markers `accessing_from`, `query_for`, `private.actor` and `private.authorize?` are where Ramal reads
      them, and `Ash.Query` has the hook fields Ramal rebuilds a query with.
    * The internal functions exist with the arity Ramal calls: Ash.Actions.Read.unpaginated_read/3,
      Ash.Actions.Sort.sorting_on_identity?/1, Ash.Actions.Read.Relationships.has_parent_expr?/1,
      Ash.Filter.list_refs/4, Ash.Filter.map/2, Ash.Filter.hydrate_refs/2, Ash.Query.do_filter/2 and
      Ash.Filter.Runtime.filter_matches/4. They are written without code quotes because Ash hides them from its docs.

  Every touch of an Ash internal goes through this module. The seam functions below the version checks are the only
  place Ramal calls an Ash internal or reads an internal context key: each names the tripwire that guards it. The seam
  test (`test/ramal/ash_seam_test.exs`) fails when any other module under `lib/` does it, so a new internal needs a seam
  here, with its tripwire, and never a direct call.

  ## Example

      iex> Ramal.Ash.check_version(:ash, "3.35.0")
      {:untested, "3.35.0", "~> 3.36.0 or ~> 3.37.0"}
  """

  @doc """
  The Hex requirement of the versions Ramal is tested with, for `:ash` or `:ash_postgres`.

  ## Example

      iex> Ramal.Ash.tested_range(:ash_postgres)
      "~> 2.15.0"
  """
  @spec tested_range(:ash | :ash_postgres) :: String.t()
  def tested_range(:ash), do: @tested_ash
  def tested_range(:ash_postgres), do: @tested_ash_postgres

  @doc """
  The version of `:ash` or `:ash_postgres` loaded on this node, or `nil` when it is not loaded. AshPostgres is optional,
  so a host without it gets `nil`.
  """
  @spec installed_version(:ash | :ash_postgres) :: String.t() | nil
  def installed_version(app) when app in [:ash, :ash_postgres] do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Checks an installed version against the tested range of `app`. `nil`, meaning not installed, is `:ok`.

  A version that `Version` cannot parse is untested rather than an error, so a host running a build with an odd version
  string gets the warning and keeps running. A pre-release of a tested version is untested too: `Version` does not match
  `3.37.0-dev` against `~> 3.37.0`, and a development build is what the range is least sure of.
  """
  @spec check_version(:ash | :ash_postgres, String.t() | nil) ::
          :ok | {:untested, String.t(), String.t()}
  def check_version(_app, nil), do: :ok

  def check_version(app, version) do
    range = tested_range(app)

    case Version.parse(version) do
      {:ok, parsed} ->
        if Enum.any?(String.split(range, " or "), &Version.match?(parsed, &1)),
          do: :ok,
          else: {:untested, version, range}

      :error ->
        {:untested, version, range}
    end
  end

  @doc """
  The warning `Ramal.Supervisor` logs for an `app` outside its tested range.

  ## Example

      iex> Ramal.Ash.untested_message(:ash, "3.35.0", "~> 3.36.0 or ~> 3.37.0") =~ "ash 3.35.0"
      true
  """
  @spec untested_message(atom, String.t(), String.t()) :: String.t()
  def untested_message(app, version, range) do
    "Ramal is running with #{app} #{version}, outside the range it is tested with (#{range}). Ramal relies on Ash " <>
      "internals listed in the docs of Ramal.Ash, and an untested version may break a branch silently. Check the " <>
      "changelog at https://github.com/agustinrojas1/ramal/blob/main/CHANGELOG.md, or open an issue at " <>
      "https://github.com/agustinrojas1/ramal/issues."
  end

  # The seams. Each is a function of Ash's internals (or of a context key Ash reads), named here once so that the rest
  # of Ramal calls it. Each comment names the tripwire that guards it and the Ash source it was confirmed in.

  # Writes

  # Tripwire: "assumption: Ash.Changeset.set_result/2 in a before_action skips the data layer" (create, update,
  # destroy). Ash: deps/ash/lib/ash/changeset/changeset.ex (set_result/2 sets context.private.action_result).
  @doc false
  @spec skip_data_layer(Ash.Changeset.t(), term) :: Ash.Changeset.t()
  def skip_data_layer(changeset, result), do: Ash.Changeset.set_result(changeset, result)

  # Tripwire: "assumption: a changeset's context.private.actor is the actor passed to the action". Ash: changeset.ex
  # (set_actor/2). A query has the same context layout; no read-side tripwire yet.
  @doc false
  @spec actor(Ash.Changeset.t() | Ash.Query.t()) :: term
  def actor(subject), do: private(subject, :actor)

  # Tripwire: "assumption: in change/3 an action with upsert? true sees context.private.upsert? == true" (and the plain
  # create and for_create/4 ones). Ash: deps/ash/lib/ash/changeset/changeset.ex (for_create/4).
  @doc false
  @spec upsert?(Ash.Changeset.t()) :: boolean
  def upsert?(changeset),
    do: changeset.action_type == :create and private(changeset, :upsert?) == true

  # Tripwire: "assumption: in change/3 an upsert with an upsert_condition sees it in context.private.upsert_condition".
  # Ash: deps/ash/lib/ash/changeset/changeset.ex (for_create/4).
  @doc false
  @spec upsert_condition(Ash.Changeset.t()) :: term
  def upsert_condition(changeset), do: private(changeset, :upsert_condition)

  # Tripwire: "assumption: in change/3 an upsert sees its upsert_identity and upsert_fields in context.private".
  # Ash: deps/ash/lib/ash/changeset/changeset.ex (for_create/4).
  @doc false
  @spec upsert_identity(Ash.Changeset.t()) :: atom | nil
  def upsert_identity(changeset), do: private(changeset, :upsert_identity)

  # Tripwire: "assumption: in change/3 an upsert sees its upsert_identity and upsert_fields in context.private".
  # Ash: deps/ash/lib/ash/changeset/changeset.ex (for_create/4).
  @doc false
  @spec upsert_fields(Ash.Changeset.t()) :: [atom] | nil
  def upsert_fields(changeset), do: private(changeset, :upsert_fields)

  # No tripwire yet. Ash sets context.private.touch_update_defaults? from the create's option, in
  # deps/ash/lib/ash/actions/create/create.ex (touch_update_defaults?, defaulting to true).
  @doc false
  @spec touch_update_defaults?(Ash.Changeset.t()) :: boolean
  def touch_update_defaults?(changeset), do: private(changeset, :touch_update_defaults?) != false

  # Reads

  # Tripwire: "assumption: a set_result in a before_action of a paginated read becomes the page's results". Ash:
  # deps/ash/lib/ash/actions/read/read.ex (run_query/4, action_result).
  @doc false
  @spec set_page(Ash.Query.t(), [struct]) :: Ash.Query.t()
  def set_page(query, rows), do: Ash.Query.set_result(query, rows)

  # Tripwire: "assumption: a set_result in a before_action of a paginated read becomes the page's results, and
  # full_count its count". Ash: deps/ash/lib/ash/actions/read/read.ex (fetch_count/5).
  @doc false
  @spec put_full_count(Ash.Query.t(), non_neg_integer) :: Ash.Query.t()
  def put_full_count(query, count), do: Ash.Query.set_context(query, %{full_count: count})

  # No tripwire yet. Ash reads context.private.internal? in deps/ash/lib/ash/actions/helpers.ex (internal?/1), which
  # exempts a read from the policy that needs an actor.
  @doc false
  @spec internal_read?(Ash.Query.t()) :: boolean
  def internal_read?(query), do: private(query, :internal?) == true

  # The mark `internal_read?/1` reads. Set by Ramal.Collation for the loads it makes to sort by a calculation.
  @doc false
  @spec mark_internal(Ash.Query.t()) :: Ash.Query.t()
  def mark_internal(query), do: Ash.Query.set_context(query, %{private: %{internal?: true}})

  # Tripwire: "assumption: a bulk update of a query reads with context.query_for == :bulk_update" (and :bulk_destroy).
  # Ash: deps/ash/lib/ash/actions/update/bulk.ex (query_for, ~l.82 and ~l.175).
  @doc false
  @spec bulk_read_for(Ash.Query.t()) :: atom | nil
  def bulk_read_for(query), do: query.context[:query_for]

  # No tripwire yet. Ash sets context.private.bypass_max_page_size? to true on the pages of a stream in
  # deps/ash/lib/ash/actions/read/stream.ex, and reads it in deps/ash/lib/ash/actions/read/read.ex (max page size).
  @doc false
  @spec bypass_max_page_size?(Ash.Query.t()) :: boolean
  def bypass_max_page_size?(query), do: private(query, :bypass_max_page_size?) == true

  # Tripwire: "assumption: a relationship read's query has context.accessing_from naming the source and the
  # relationship". Ash: deps/ash/lib/ash/actions/read/relationships.ex (accessing_from).
  @doc false
  @spec relationship_read?(Ash.Query.t()) :: boolean
  def relationship_read?(query), do: Map.has_key?(query.context, :accessing_from)

  # The same tripwire as `relationship_read?/1`: the value is the source and the relationship name.
  @doc false
  @spec accessing_from(Ash.Query.t()) :: %{source: module, name: atom} | nil
  def accessing_from(query), do: query.context[:accessing_from]

  # Tripwire: "assumption: a query run with authorize?: false has context.private.authorize? == false". Ash:
  # deps/ash/lib/ash/query/query.ex (set_authorize?/2).
  @doc false
  @spec authorize_opts(Ash.Query.t()) :: keyword
  def authorize_opts(query) do
    case query.context[:private] do
      %{authorize?: authorize?} -> [authorize?: authorize?]
      _none -> []
    end
  end

  # Tripwire: "assumption: Ash.Query has the fields Ramal rebuilds a query with". Ash: deps/ash/lib/ash/query/query.ex
  # (defstruct). Empties the hooks of a query, so that a read of its rows runs none of them.
  @doc false
  @spec without_hooks(Ash.Query.t()) :: Ash.Query.t()
  def without_hooks(query) do
    %{
      query
      | before_action: [],
        after_action: [],
        before_transaction: [],
        after_transaction: [],
        around_transaction: []
    }
  end

  # Tripwire: "assumption: Ash.Actions.Read.unpaginated_read/3 returns every row when the read's default_limit is
  # lower". Ash: deps/ash/lib/ash/actions/read/read.ex (unpaginated_read/3).
  @doc false
  @spec unpaginated_read(Ash.Query.t(), keyword) :: {:ok, [struct]} | {:error, term}
  def unpaginated_read(query, opts), do: Read.unpaginated_read(query, nil, opts)

  # Tripwire: "assumption: Ash.Sort.runtime_sort/3 is exported". Ash: deps/ash/lib/ash/sort/sort.ex, which
  # delegates Ash.Sort.runtime_sort/3 to deps/ash/lib/ash/actions/sort.ex. Ramal calls the public name.
  @doc false
  @spec runtime_sort([struct], term, keyword) :: [struct]
  def runtime_sort(rows, sort, opts), do: Ash.Sort.runtime_sort(rows, sort, opts)

  # Tripwire: "assumption: Ash.Actions.Sort.sorting_on_identity?/1 is exported". Ash: deps/ash/lib/ash/actions/sort.ex.
  @doc false
  @spec sorting_on_identity?(Ash.Query.t()) :: boolean
  def sorting_on_identity?(query), do: Sort.sorting_on_identity?(query)

  # Tripwire: "assumption: Ash.Filter.list_refs/4 is exported". Ash: deps/ash/lib/ash/filter/filter.ex (list_refs).
  # Confirmed in 3.37: the refs of an `exists(...)` carry the path of the exists prefixed; the refs inside an expression
  # calculation are listed only when asked to expand calculations; a filter that names an aggregate holds an
  # `Ash.Query.Aggregate` as the ref's attribute, and a sort on one holds it in place of the field name.
  @doc false
  @spec filter_refs(term, boolean) :: [map]
  def filter_refs(expression, expand_calculations?),
    do: Ash.Filter.list_refs(expression, false, false, expand_calculations?)

  # Tripwire: "assumption: Ash.Filter.map/2 is exported". Ash: deps/ash/lib/ash/filter/filter.ex (map/2, ~l.1618). It
  # visits a Ref through the function and stops on `{:halt, expression}`.
  @doc false
  @spec map_filter(term, (term -> term)) :: term
  def map_filter(filter, fun), do: Ash.Filter.map(filter, fun)

  # Tripwire: "assumption: Ash.Filter.hydrate_refs/2 is exported". Ash: deps/ash/lib/ash/filter/filter.ex (~l.4226).
  @doc false
  @spec hydrate_refs(term, module) :: {:ok, term} | {:error, term}
  def hydrate_refs(expression, resource),
    do:
      Ash.Filter.hydrate_refs(expression, %{
        resource: resource,
        relationship_path: [],
        public?: false
      })

  # Tripwire: "assumption: Ash.Filter.Runtime.filter_matches/4 is exported". Ash: deps/ash/lib/ash/filter/runtime.ex
  # (filter_matches/4, ~l.19). It keeps a record unless the filter gives `false` or `nil`, so an unknown is no match.
  @doc false
  @spec filter_matches(module | nil, [struct], term) :: {:ok, [struct]} | {:error, term}
  def filter_matches(domain, records, filter),
    do: Runtime.filter_matches(domain, records, filter)

  # Tripwire: "assumption: Ash.Query.do_filter/2 is exported". Ash: deps/ash/lib/ash/query/query.ex (do_filter/3,
  # @doc false). Ash's own filter step with no validation of the filter, which the keyset cursor and the lookups of
  # Ramal.Capture and Ramal.Merge use.
  @doc false
  @spec do_filter(Ash.Query.t(), term) :: Ash.Query.t()
  def do_filter(query, filter), do: Ash.Query.do_filter(query, filter)

  # Relationship loads through the branch

  # Tripwire: "assumption: a has_many load with a query limit reaches the destination read with lateral_join_source and
  # tagged rows". Ash: deps/ash/lib/ash/actions/read/relationships.ex (lateral_join?/4, with_lateral_join_query/4).
  @doc false
  @spec lateral_source(Ash.Query.t()) :: {[struct], list} | nil
  def lateral_source(query), do: get_in(query.context, [:data_layer, :lateral_join_source])

  # The same tripwire: a lateral load is one whose query carries its source records.
  @doc false
  @spec lateral_load?(Ash.Query.t()) :: boolean
  def lateral_load?(query), do: match?({_, _}, lateral_source(query))

  # The same tripwire. Drops the lateral join from the destination read, so the query runs as a plain read.
  @doc false
  @spec drop_lateral_source(Ash.Query.t()) :: Ash.Query.t()
  def drop_lateral_source(query) do
    update_in(
      query.context[:data_layer],
      &if(&1, do: Map.delete(&1, :lateral_join_source), else: &1)
    )
  end

  # The same tripwire. Puts a lateral join back on the query, as Ash puts it on a relationship read.
  @doc false
  @spec put_lateral_source(Ash.Query.t(), {[struct], list}) :: Ash.Query.t()
  def put_lateral_source(query, source),
    do: Ash.Query.set_context(query, %{data_layer: %{lateral_join_source: source}})

  # The same tripwire: the source record a row of a lateral load belongs to. Every resource struct has the field.
  @doc false
  @spec lateral_tag(struct) :: struct | nil
  def lateral_tag(record), do: record.__lateral_join_source__

  # The same tripwire. Tags a row with the source record it belongs to.
  @doc false
  @spec tag_lateral(struct, struct) :: struct
  def tag_lateral(record, source), do: %{record | __lateral_join_source__: source}

  # Tripwire: "assumption: Ash.Actions.Read.Relationships.has_parent_expr?/1 is exported". Ash:
  # deps/ash/lib/ash/actions/read/relationships.ex (has_parent_expr?/1, ~l.1989).
  @doc false
  @spec has_parent_expr?(map) :: boolean
  def has_parent_expr?(relationship),
    do: Relationships.has_parent_expr?(relationship)

  defp private(subject, key), do: get_in(subject.context, [:private, key])
end
