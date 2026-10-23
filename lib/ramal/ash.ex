defmodule Ramal.Ash do
  @tested_ash "~> 3.36.0 or ~> 3.37.0"
  @tested_ash_postgres "~> 2.15.0"

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
    * The internal functions `Ash.Actions.Read.unpaginated_read/3`, `Ash.Actions.Sort.runtime_sort/3` and
      `sorting_on_identity?/1`, `Ash.Actions.Read.Relationships.has_parent_expr?/1`, `Ash.Filter.list_refs/4`,
      `Ash.Filter.map/2` and `Ash.Filter.Runtime.filter_matches/4` exist with the arity Ramal calls.

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
end
