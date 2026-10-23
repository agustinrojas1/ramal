defmodule Ramal.ModelMapTest do
  # The formal models under verification/ state rules the code in lib/ follows, and nothing in the build reads one
  # against the other. verification/model_map.exs names, step by step, the functions each step of each model stands
  # for, and these tests fail when the two are no longer talking about the same thing: a function renamed, a module
  # added that no model reads, or the code of a step changed since its step in the model was last checked (ADR 0050).
  # No database is used.
  use ExUnit.Case, async: true

  alias Ramal.ModelMap

  @root Path.expand("../..", __DIR__)
  @workflow Path.join(@root, ".github/workflows/verification.yml")

  # STAMP=1 records the code as checked against the models, before any test compares them.
  setup_all do
    data = ModelMap.load()
    if System.get_env("STAMP") == "1", do: ModelMap.write_stamps(data)
    %{data: data, index: ModelMap.index_code()}
  end

  test "every function the map names exists", %{data: data, index: index} do
    missing =
      for step <- data.steps,
          ref <- step.code,
          ModelMap.resolve(ref, index) == :error,
          do: "#{ModelMap.id(step)}: #{ref}"

    assert missing == [],
           "verification/model_map.exs names functions that are not in lib/ (renamed, or another arity?). Fix the " <>
             "name here, and in the model's comment, after checking the step still describes what the function does:\n  " <>
             Enum.join(missing, "\n  ")
  end

  test "every step the map names is defined in its model", %{data: data} do
    missing =
      for step <- data.steps,
          not MapSet.member?(ModelMap.defined_steps(step.model), step.step),
          do: "#{step.model}: #{step.step}"

    assert missing == [],
           "verification/model_map.exs names steps the model does not define (renamed in the model?):\n  " <>
             Enum.join(missing, "\n  ")
  end

  test "every function a .tla file cites exists and is mapped to a step of that file", %{
    data: data,
    index: index
  } do
    mapped =
      for step <- data.steps,
          ref <- step.code,
          {:ok, key} <- [ModelMap.resolve(ref, index)],
          into: MapSet.new() do
        {Path.basename(step.model), key}
      end

    problems =
      for {file, ref} <- ModelMap.cited(),
          problem = cited_problem(file, ref, index, mapped),
          do: problem

    assert problems == [],
           "a comment in verification/tla cites code the map does not know. Rename the citation, or add the function " <>
             "to the step that models it in verification/model_map.exs:\n  " <>
             Enum.join(problems, "\n  ")
  end

  test "every file under lib/ is read by a model or says why no model needs it", %{
    data: data,
    index: index
  } do
    modelled =
      for step <- data.steps,
          ref <- step.code,
          {:ok, {mod, _, _}} <- [ModelMap.resolve(ref, index)],
          into: MapSet.new(),
          do: ModelMap.file_of(mod, index)

    files = ModelMap.lib_files()
    excused = data.not_modelled |> Map.keys() |> MapSet.new()

    unclassified = files |> Enum.reject(&(&1 in modelled or &1 in excused))
    both = MapSet.intersection(modelled, excused) |> Enum.sort()
    gone = excused |> Enum.reject(&(&1 in files)) |> Enum.sort()

    assert unclassified == [],
           "these files are new, or no longer hold a modelled function. If a model's rules depend on one, make a step " <>
             "of verification/tla cite its function in verification/model_map.exs; otherwise add it to `not_modelled` " <>
             "with the reason (a refusal, the read side, a struct):\n  " <>
             Enum.join(unclassified, "\n  ")

    assert both == [],
           "listed as not modelled, yet a step models a function in them:\n  " <>
             Enum.join(both, "\n  ")

    assert gone == [],
           "listed as not modelled, but gone from lib/:\n  " <> Enum.join(gone, "\n  ")
  end

  test "the code of every step is the code its model was last checked against", %{data: data} do
    stored = ModelMap.stored_stamps()
    current = ModelMap.current_stamps(data)

    changed = for {id, hash} <- current, Map.get(stored, id) != hash, do: id
    stale = for {id, _} <- stored, not is_map_key(current, id), do: id

    assert changed == [] and stale == [], drift_message(data, changed, stale)
  end

  test "the Verification workflow runs when a modelled file changes", %{data: data, index: index} do
    patterns = workflow_paths()

    modelled =
      for step <- data.steps,
          ref <- step.code,
          {:ok, {mod, _, _}} <- [ModelMap.resolve(ref, index)],
          into: MapSet.new(),
          do: ModelMap.file_of(mod, index)

    uncovered = for file <- modelled, not Enum.any?(patterns, &glob?(&1, file)), do: file
    needed = ["verification/tla/Ramal.tla", ".github/workflows/verification.yml"]
    missing = for file <- needed, not Enum.any?(patterns, &glob?(&1, file)), do: file

    assert uncovered ++ missing == [],
           "the `paths` of .github/workflows/verification.yml must list every file a model reads, so a change to one " <>
             "reruns TLC and Bend. Add:\n  " <> Enum.join(uncovered ++ missing, "\n  ")
  end

  defp cited_problem(file, ref, index, mapped) do
    case ModelMap.resolve(ref, index) do
      :error ->
        "#{file} cites #{ref}, which is not in lib/"

      {:ok, key} ->
        unless MapSet.member?(mapped, {file, key}),
          do: "#{file} cites #{ref}, which no step of it maps"
    end
  end

  defp drift_message(data, changed, stale) do
    steps = Map.new(data.steps, &{ModelMap.id(&1), &1})

    moved =
      for id <- Enum.sort(changed) do
        case steps[id] do
          nil -> "  #{id}  (a step the map has now)"
          step -> "  #{id}\n      #{step.why}\n      code: #{Enum.join(step.code, ", ")}"
        end
      end

    """
    The code a formal model stands for changed since the model was last checked against it (ADR 0050).

    #{Enum.join(moved, "\n")}
    #{if stale == [], do: "", else: "Stamps of steps the map no longer has: #{Enum.join(stale, ", ")}"}

    For each step above, read it in verification/tla (or verification/bend) next to the new code. If the rule the step
    states still holds, nothing else changes. If not, change the model and its properties in this PR, run
    verification/check.sh, and add a bug-*.cfg when the change closes a bug. Then record that you looked:

        STAMP=1 mix test test/ramal/model_map_test.exs

    and commit verification/model_map.stamps. Name the steps you checked in the PR description.
    """
  end

  # The `paths:` of the pull_request trigger: the quoted entries of the list under it.
  defp workflow_paths do
    @workflow
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(not String.contains?(&1, "pull_request:")))
    |> Enum.take_while(
      &(&1 == "" or String.starts_with?(&1, " ") or String.starts_with?(&1, "-"))
    )
    |> Enum.flat_map(&(Regex.run(~r/^\s+- "([^"]+)"\s*$/, &1, capture: :all_but_first) || []))
  end

  defp glob?(pattern, path) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/\A#{regex}\z/, path)
  end
end
