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

  Ash does not present these as public API, so a minor release may change them. The modules that call each one say why
  the public API is not enough:

    * `Ash.Filter.Runtime.filter_matches/3` and `/4`: judge a filter on the rows of a branch, in Elixir
      (`Ramal.Preparation`, `Ramal.Preparation.Related`, `Ramal.Preparation.Paged`)
    * `Ash.Filter.list_refs/4` and `/5`, `Ash.Filter.hydrate_refs/2`: the fields and relationships a filter or sort names
      (`Ramal.Preparation.Related`, `Ramal.Collation`)
    * `Ash.Actions.Sort.runtime_sort/3` and `sorting_on_identity?/1`: order rows in Elixir
      (`Ramal.Collation`, `Ramal.Aggregate`, `Ramal.Preparation.Paged`)
    * `Ash.Actions.Read.Relationships.has_parent_expr?/1`: tells a relationship load that walks through the branch's rows
      (`Ramal.Preparation.Lateral`, `Ramal.Preparation.ManyToMany`)
    * `Ash.Query.Aggregate` and `Ash.Query.Calculation`: the structs of an aggregate and a calculation, matched on their
      fields (`Ramal.Preparation.Related`, `Ramal.Preparation.Aggregates`, `Ramal.Collation`)

  Ramal's calls are listed here so that a change in Ash has one place to look. Moving more of them into this module is
  planned, not done.

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
