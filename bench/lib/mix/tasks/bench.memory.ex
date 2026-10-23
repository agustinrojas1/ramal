defmodule Mix.Tasks.Bench.Memory do
  @shortdoc "Prints what a branch costs in memory for 100, 1,000 and 5,000 updated rows"
  @moduledoc false
  # mix bench.memory [--sizes 100,1000]
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

    Bench.Memory.run(sizes)
  end
end
