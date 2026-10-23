defmodule Ramal.DocsTest do
  use ExUnit.Case, async: true

  # CLAUDE.md: every public module has a @moduledoc with an example, every public function has @doc and @spec.
  # "Public" is a module with a moduledoc other than `false`; the test support modules are not part of lib.
  @modules for module <- Application.spec(:ramal, :modules),
               String.contains?(to_string(module.module_info(:compile)[:source]), "/lib/"),
               do: module

  # Defined by `use Supervisor` and `use Ash.Resource.Preparation`, not written here.
  @generated [
    {Ramal.Supervisor, :child_spec, 1},
    {Ramal.Preparation, :init, 1},
    {Ramal.Preparation, :supports, 1},
    {Ramal.Preparation, :temporal_safe?, 1}
  ]

  defp docs(module) do
    {:docs_v1, _anno, _lang, _format, moduledoc, _meta, entries} = Code.fetch_docs(module)
    {moduledoc, entries}
  end

  defp documented_modules do
    Enum.filter(@modules, fn module ->
      {moduledoc, _entries} = docs(module)
      moduledoc != :hidden
    end)
  end

  test "the public modules are the ones the design names" do
    names = documented_modules() |> Enum.map(&inspect/1) |> Enum.sort()

    assert names == [
             "Mix.Tasks.Ramal.Doctor",
             "Mix.Tasks.Ramal.Gen.Migration",
             "Ramal",
             "Ramal.Aggregate",
             "Ramal.Ash",
             "Ramal.Branch",
             "Ramal.Capture",
             "Ramal.Change",
             "Ramal.Error",
             "Ramal.Merge",
             "Ramal.Merge.Result",
             "Ramal.Overlay",
             "Ramal.Preparation",
             "Ramal.Resource",
             "Ramal.Storage",
             "Ramal.Storage.Codec",
             "Ramal.Storage.ETS",
             "Ramal.Storage.Postgres",
             "Ramal.Supervisor",
             "Ramal.Telemetry",
             "Ramal.Tools"
           ]
  end

  test "every public module has a moduledoc with an example" do
    missing =
      for module <- documented_modules(),
          {%{"en" => moduledoc}, _} = docs(module),
          not (moduledoc =~ ~r/## Example|iex>/),
          do: inspect(module)

    assert missing == []
  end

  test "every public function has a doc and a spec" do
    missing =
      for module <- documented_modules(),
          {:ok, specs} = Code.Typespec.fetch_specs(module),
          specced = MapSet.new(specs, fn {{name, arity}, _} -> {name, arity} end),
          {{:function, name, arity}, _anno, _signature, doc, meta} <- elem(docs(module), 1),
          doc != :hidden,
          not Map.has_key?(meta, :implementation_of),
          {module, name, arity} not in @generated,
          problem <- [
            if(doc == :none, do: "has no @doc"),
            if({name, arity} not in specced, do: "has no @spec")
          ],
          problem != nil,
          do: "#{inspect(module)}.#{name}/#{arity} #{problem}"

    assert missing == []
  end
end
