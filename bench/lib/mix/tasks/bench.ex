defmodule Mix.Tasks.Bench do
  @shortdoc "Runs the Ramal benchmark (--quick for a smoke run)"
  @moduledoc false
  # mix bench [--quick] [--only fork,read] [--no-json]
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [quick: :boolean, only: :string, no_json: :boolean])

    Mix.Task.run("app.start")

    cases =
      case opts[:only] do
        nil -> Bench.cases()
        list -> list |> String.split(",") |> Enum.map(&only!/1)
      end

    Bench.run(if(opts[:quick], do: :quick, else: :full), cases: cases, no_json: opts[:no_json])
  end

  # The names are matched against the known cases instead of being turned into atoms.
  defp only!(name) do
    Enum.find(Bench.cases(), &(Atom.to_string(&1) == name)) ||
      Mix.raise("unknown case #{name}; known: #{Enum.join(Bench.cases(), ", ")}")
  end
end
