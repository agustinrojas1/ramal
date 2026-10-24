defmodule Mix.Tasks.Bench.Hibernation do
  @shortdoc "Measures idle branch process memory and wake cost for hibernation (issue #274)"
  @moduledoc false
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [sizes: :string])
    Mix.Task.run("app.start")

    sizes =
      case opts[:sizes] do
        nil -> []
        list -> [sizes: list |> String.split(",") |> Enum.map(&String.to_integer/1)]
      end

    Bench.Hibernation.run(sizes)
  end
end