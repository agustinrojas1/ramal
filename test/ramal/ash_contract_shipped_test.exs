defmodule Ramal.AshContractShippedTest do
  # The Ash contract that ships with Ramal (`Ramal.Ash.Contract`, ADR 0049), checked on the locked Ash: every check
  # passes, every tripwire names a test that exists in test/ramal/ash_contract_test.exs, and the table itself is sound.
  # This file reads the tripwire file as text, so a renamed test fails here with the assumption's id.
  #
  # Read-only: nothing here changes the broken ids, which are a value for the whole node (see ash_incompatible_test.exs).
  use ExUnit.Case, async: true

  alias Ramal.Ash.Contract

  @tripwires Path.expand("ash_contract_test.exs", __DIR__)
  @tiers [:core, :extended]
  @features [:core, :bulk, :upsert, :relationship_pages]

  # The names of the tests in the tripwire file: the literal ones, and the generated export tests, which are named from
  # the `{module, function, arity, ramal, ash}` tuples of the `for` that generates them.
  defp tripwire_names do
    source = File.read!(@tripwires)

    literal =
      ~r/^\s*test "(assumption: [^"#]*)" do$/m
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()

    generated =
      ~r/\{([\w.]+), :([\w?!]+), (\d+), "([^"]+)",\s*"([^"]+)"\}/
      |> Regex.scan(source, capture: :all_but_first)
      |> Enum.map(fn [module, function, arity, ramal, ash] ->
        "assumption: #{module}.#{function}/#{arity} is exported (Ramal calls it in #{ramal}; from #{ash})"
      end)

    literal ++ generated
  end

  test "the shipped checks pass on the locked Ash and AshPostgres" do
    broken = for {id, outcome} <- Contract.run(), outcome != :ok, do: {id, outcome}

    assert broken == []
  end

  test "every tripwire names a test that exists in test/ramal/ash_contract_test.exs" do
    names = MapSet.new(tripwire_names())

    missing =
      for %{id: id, tripwire: tripwire} <- Contract.assumptions(),
          not MapSet.member?(names, tripwire),
          do: "#{id}: #{tripwire}"

    assert missing == []
  end

  test "the generated export tests are found in the tripwire file" do
    generated = Enum.filter(tripwire_names(), &String.contains?(&1, " is exported ("))

    assert length(generated) == 9
  end

  test "every assumption has a unique id, a summary and a tripwire" do
    assumptions = Contract.assumptions()
    ids = Enum.map(assumptions, & &1.id)

    assert ids == Enum.uniq(ids)

    for %{id: id, summary: summary, tripwire: tripwire} <- assumptions do
      assert is_binary(summary) and summary != "", "#{id} has no summary"
      assert String.starts_with?(tripwire, "assumption: "), "#{id} is not a tripwire name"
    end
  end

  test "every tier and feature is one of the allowed values, and core is the core feature" do
    for %{id: id, tier: tier, feature: feature} <- Contract.assumptions() do
      assert tier in @tiers, "#{id} has tier #{inspect(tier)}"
      assert feature in @features, "#{id} has feature #{inspect(feature)}"
      assert tier == :core == (feature == :core), "#{id} is #{tier} but serves #{feature}"
    end
  end

  test "the moduledoc of Ramal.Ash names every assumption" do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _entries} =
      Code.fetch_docs(Ramal.Ash)

    missing =
      for %{id: id} <- Contract.assumptions(),
          not String.contains?(moduledoc, "`#{id}`"),
          do: id

    assert missing == []
  end
end
