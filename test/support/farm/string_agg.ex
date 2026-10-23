defmodule Ramal.Test.Farm.StringAgg do
  @moduledoc false
  # A custom aggregate: a data-layer module that produces SQL, which the preparation cannot recompute from the branch's
  # rows.
  use AshPostgres.CustomAggregate

  require Ecto.Query

  @impl true
  def dynamic(opts, binding) do
    Ecto.Query.dynamic(
      [],
      fragment("string_agg(?, ?)", field(as(^binding), ^opts[:field]), ^opts[:delimiter])
    )
  end
end
