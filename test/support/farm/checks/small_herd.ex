defmodule Ramal.Test.Farm.Checks.SmallHerd do
  @moduledoc false
  # A check Ash can only run on the rows a read returned: `strict_check` cannot decide, so the policy (with the
  # runtime access type) puts an `authorize_results` hook on the query and the rows are judged after the data layer
  # (`lib/ash/can.ex`, Ash 3.37).
  use Ash.Policy.Check

  @impl true
  def describe(_options), do: "the herd has at most 100 head"

  @impl true
  def strict_check(_actor, _authorizer, _options), do: {:ok, :unknown}

  @impl true
  def check(_actor, records, _authorizer, _options), do: Enum.filter(records, &(&1.head <= 100))
end
