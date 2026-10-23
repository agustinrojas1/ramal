defmodule Ramal.Test.Farm.Calculations.Doubled do
  @moduledoc false
  # A calculation with its own module that also has an expression: Ash hands it to the data layer.
  use Ash.Resource.Calculation

  @impl true
  def expression(_opts, _context), do: expr(head * 2)
end

defmodule Ramal.Test.Farm.Calculations.Shouted do
  @moduledoc false
  # A calculation with its own module and no expression: Ash runs it in Elixir after the read.
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, &String.upcase(&1.name))
end
