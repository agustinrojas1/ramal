defmodule Ramal.Resource.Verifier do
  @moduledoc false
  # Says at compile time what a branch handles only in part, instead of leaving it to the first action that fails or to
  # a telemetry event a host has to know about. A warning and not an error: the resource still works, only not with
  # every action, so the build goes on.
  #
  # A verifier runs after the module is compiled (`Spark.Dsl.Verifier`), so it reads the resource's own attributes and
  # aggregates without a compile-time dependency on another module, and it returns `{:warn, message}` (Spark 2.7.8),
  # which the host sees as a compiler warning. `ramal do warnings?(false) end` turns it off for a resource that keeps a
  # limitation on purpose.
  use Spark.Dsl.Verifier

  alias Ash.Resource.Info
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if branchable?(dsl_state) and warned?(dsl_state) do
      case warnings(Verifier.get_persisted(dsl_state, :module)) do
        [] -> :ok
        warnings -> {:warn, warnings}
      end
    else
      :ok
    end
  end

  defp branchable?(dsl_state), do: Verifier.get_option(dsl_state, [:ramal], :branchable?, true)
  defp warned?(dsl_state), do: Verifier.get_option(dsl_state, [:ramal], :warnings?, true)

  defp warnings(resource) do
    generated_key(resource) ++ custom_aggregates(resource)
  end

  # `Ramal.Capture` gives a database-generated primary key a placeholder that the merge renames to the key the
  # replayed create got (ADR 0042). `Ramal.Branch.placeholder/2` has one for an integer and one for a UUID, and
  # only for a single key: every other create inside a branch fails with `:database_generated_key`.
  defp generated_key(resource) do
    keys = Info.primary_key(resource)
    generated = Enum.filter(keys, &Info.attribute(resource, &1).generated?)

    cond do
      generated == [] ->
        []

      match?([_key], keys) and placeholdable?(Info.attribute(resource, hd(keys)).type) ->
        []

      true ->
        [
          "#{inspect(resource)}: a branch cannot create a row whose primary key the database generates, " <>
            "unless it is one key of type :integer, :uuid or :uuid_v7; a create inside a branch fails with " <>
            ":database_generated_key. Give the key a default in Elixir, as `uuid_primary_key` does, or set " <>
            "`branchable? false` (docs/limits.md, ADR 0042)"
        ]
    end
  end

  defp placeholdable?(type) when type in [Ash.Type.Integer, Ash.Type.UUID, Ash.Type.UUIDv7],
    do: true

  defp placeholdable?(_type), do: false

  # A `custom` aggregate is SQL the preparation cannot recompute from the branch's rows, so a read that loads one keeps
  # the database's value and emits `[:ramal, :read, :unpatched_aggregate]` (ADR 0029).
  defp custom_aggregates(resource) do
    for %{kind: :custom, name: name} <- Info.aggregates(resource) do
      "#{inspect(resource)}.#{name}: a branch keeps the database's value for a custom aggregate and emits " <>
        "[:ramal, :read, :unpatched_aggregate] on each read that loads it (docs/limits.md)"
    end
  end
end
