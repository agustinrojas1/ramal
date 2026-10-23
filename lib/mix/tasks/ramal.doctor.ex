defmodule Mix.Tasks.Ramal.Doctor do
  @shortdoc "Checks each Ash assumption Ramal relies on, on the Ash this project runs"

  @moduledoc """
  Runs every check of Ramal's Ash contract on the Ash and AshPostgres this project runs, and prints one line per
  assumption.

  Run it after upgrading Ash. It checks each Ash behaviour Ramal relies on against the version you run, on small
  resources of its own, so it needs no database and does not start your application. It prints the installed Ash and
  AshPostgres against the range Ramal is tested with, then one line per assumption: the result (`ok`, `BROKEN` or
  `not checked`), its tier, the feature it serves and its summary. A broken assumption gets the reason on the line
  below. The last line is the verdict.

  The exit status is 1 when a core assumption is broken, because Ramal then refuses every read and write inside a
  branch with `:ash_incompatible`; it is 0 otherwise. A broken extended assumption refuses only its feature (bulk
  actions, upserts, or relationship loads inside a branch), and the verdict names it.

  ## Example

      $ mix ramal.doctor
      Ramal 0.9.1 on Ash 3.37.0 (tested: ~> 3.36.0 or ~> 3.37.0) and AshPostgres 2.15.1 (tested: ~> 2.15.0)

        ok           core      core               set_result_create               a set_result in a before_action skips the data layer on create
        ok           core      core               set_result_update               a set_result in a before_action skips the data layer on update
        ok           core      core               set_result_destroy              a set_result in a before_action skips the data layer on destroy
        ...
        ok           extended  upsert             upsert_condition                change/3 of an upsert with a condition sees the condition
        ok           extended  relationship_pages lateral_join_source             a has_many load with a limit reaches its read with the source records and tagged rows
        ok           extended  relationship_pages export_has_parent_expr          Ash.Actions.Read.Relationships.has_parent_expr?/1 is exported

      Verdict: ok. 34 checks passed.

  A broken line is `BROKEN`, with its reason on the line below it, and the verdict then names what Ramal refuses.
  """

  use Mix.Task

  alias Ramal.Ash
  alias Ramal.Ash.Contract

  @id_width 32
  @label_width 13
  @tier_width 10
  @feature_width 19

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    # `app.config` compiles the project and loads its config without starting it, so no repo connects.
    Mix.Task.run("app.config")
    {:ok, _started} = Application.ensure_all_started(:ash)

    env = %{
      ramal: version(:ramal),
      ash: Ash.installed_version(:ash),
      ash_postgres: Ash.installed_version(:ash_postgres)
    }

    {report, status} = render(Contract.run(), env)
    Mix.shell().info(report)

    if status != 0, do: exit({:shutdown, status})
    :ok
  end

  @doc false
  # The report for a list of results (as `Ramal.Ash.Contract.run/0` returns them) and the versions it ran on, with the
  # exit status it implies: 1 when a core assumption is broken, 0 otherwise.
  @spec render([{atom, Contract.outcome()}], map) :: {String.t(), 0 | 1}
  def render(results, env) do
    assumptions = Map.new(Contract.assumptions(), &{&1.id, &1})
    rows = for {id, outcome} <- results, do: row(Map.fetch!(assumptions, id), outcome)
    broken = for {id, {:broken, _reason}} <- results, do: Map.fetch!(assumptions, id)

    lines =
      [header(env), ""] ++
        Enum.flat_map(rows, & &1) ++
        ["", verdict(results, broken, env)]

    {Enum.join(lines, "\n"), status(broken)}
  end

  defp header(env) do
    "Ramal #{env.ramal} on Ash #{version_text(env.ash, :ash)} and AshPostgres #{version_text(env.ash_postgres, :ash_postgres)}"
  end

  defp version_text(nil, _app), do: "not installed"

  defp version_text(version, app) do
    case Ash.check_version(app, version) do
      :ok -> "#{version} (tested: #{Ash.tested_range(app)})"
      {:untested, _version, range} -> "#{version} (outside the tested range #{range})"
    end
  end

  defp row(%{id: id, tier: tier, feature: feature, summary: summary}, outcome) do
    {label, reason} =
      case outcome do
        :ok -> {"ok", nil}
        {:broken, reason} -> {"BROKEN", reason}
        :not_checked -> {"not checked", nil}
      end

    line =
      "  " <>
        String.pad_trailing(label, @label_width) <>
        String.pad_trailing(to_string(tier), @tier_width) <>
        String.pad_trailing(to_string(feature), @feature_width) <>
        String.pad_trailing(to_string(id), @id_width) <> summary

    if reason,
      do: [line, "  " <> String.duplicate(" ", @label_width) <> "reason: " <> reason],
      else: [line]
  end

  defp verdict(results, [], _env) do
    checked = Enum.count(results, fn {_id, outcome} -> outcome != :not_checked end)
    not_checked = length(results) - checked

    "Verdict: ok. #{checked} checks passed" <>
      if(not_checked > 0, do: ", #{not_checked} not checked", else: "") <> "."
  end

  defp verdict(_results, broken, env) do
    ids = Enum.map_join(broken, ", ", & &1.id)

    case Enum.find(broken, &(&1.tier == :core)) do
      nil ->
        features =
          broken |> Enum.map(& &1.feature) |> Enum.uniq() |> Enum.map_join(", ", &feature_name/1)

        "Verdict: partly broken on Ash #{env.ash}. Ramal refuses #{features} inside a branch (#{ids}); " <>
          "everything else works."

      _core ->
        "Verdict: BROKEN on Ash #{env.ash}. Ramal refuses every read and write inside a branch: " <>
          "#{length(Enum.filter(broken, &(&1.tier == :core)))} core assumption(s) broken (#{ids})."
    end
  end

  defp status(broken), do: if(Enum.any?(broken, &(&1.tier == :core)), do: 1, else: 0)

  defp feature_name(:bulk), do: "bulk actions"
  defp feature_name(:upsert), do: "upserts"
  defp feature_name(:relationship_pages), do: "lateral relationship loads"
  defp feature_name(:core), do: "branch reads and writes"

  defp version(app) do
    case Application.spec(app, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end
end
