defmodule Ramal.AggregatePropertyTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false
  use ExUnitProperties

  require Ash.Query

  alias Ramal.Aggregate

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, Seeds.seed!()}
  end

  # What a branch can do to herds, as data. Indexes are taken modulo the rows alive at that point.
  defp operation do
    one_of([
      tuple({constant(:create), integer(0..60), integer(-1..1)}),
      tuple({constant(:update), integer(0..20), integer(0..60)}),
      tuple({constant(:destroy), integer(0..20)})
    ])
  end

  defp herd_filter do
    one_of([
      constant(:none),
      tuple({constant(:at_least), integer(0..60)}),
      tuple({constant(:in_paddock), integer(0..1)})
    ])
  end

  defp apply_operation({:create, head, paddock}, live, ctx) do
    paddock_id = if paddock >= 0, do: Enum.at(ctx.paddocks, paddock).id

    herd =
      Ash.create!(
        Herd,
        %{name: "P#{System.unique_integer([:positive])}", head: head, paddock_id: paddock_id},
        authorize?: false
      )

    [herd | live]
  end

  defp apply_operation({:update, _index, _head}, [] = live, _ctx), do: live

  defp apply_operation({:update, index, head}, live, _ctx) do
    {herd, rest} = List.pop_at(live, rem(index, length(live)))
    [Ash.update!(herd, %{head: head}, authorize?: false) | rest]
  end

  defp apply_operation({:destroy, _index}, [] = live, _ctx), do: live

  defp apply_operation({:destroy, index}, live, _ctx) do
    {herd, rest} = List.pop_at(live, rem(index, length(live)))
    Ash.destroy!(herd, authorize?: false)
    rest
  end

  defp query(:none, _ctx), do: Herd
  defp query({:at_least, head}, _ctx), do: Ash.Query.filter(Herd, head >= ^head)

  defp query({:in_paddock, index}, ctx) do
    id = Enum.at(ctx.paddocks, index).id
    Ash.Query.filter(Herd, paddock_id == ^id)
  end

  property "the delta answer equals the answer of reading every row, for every kind", %{
    herds: herds,
    paddocks: paddocks
  } do
    ctx = %{paddocks: [paddocks.l07, paddocks.l18]}

    check all(
            operations <- list_of(operation(), max_length: 12),
            filter <- herd_filter(),
            max_runs: 40
          ) do
      {:ok, branch} = Ramal.branch(Farm)

      Ramal.run!(branch, fn ->
        Enum.reduce(operations, Map.values(herds), &apply_operation(&1, &2, ctx))

        query = query(filter, ctx)
        rows = Ash.read!(query, authorize?: false)

        for kind <- Aggregate.kinds() do
          field = if kind in [:count, :exists], do: nil, else: :head
          expected = Aggregate.compute(kind, field, rows, Herd, shape(kind))
          actual = Ramal.aggregate!(query, kind, field, authorize?: false)

          assert close?(actual, expected),
                 "#{kind} gave #{inspect(actual)}, reading every row gives #{inspect(expected)}"
        end
      end)

      :ok = Ramal.discard(branch)
    end
  end

  property "a nullable field, with rows the branch gives and takes away values from", %{
    paddocks: paddocks
  } do
    check all(
            hectares <-
              list_of(one_of([constant(nil), float(min: 0.0, max: 100.0)]), max_length: 6),
            drop_one? <- boolean(),
            max_runs: 30
          ) do
      {:ok, branch} = Ramal.branch(Farm)

      Ramal.run!(branch, fn ->
        for h <- hectares do
          Ash.create!(
            Paddock,
            %{name: "N#{System.unique_integer([:positive])}", hectares: h, capacity_head: 10},
            authorize?: false
          )
        end

        if drop_one?, do: Ash.update!(paddocks.l07, %{hectares: nil}, authorize?: false)

        rows = Ash.read!(Paddock, authorize?: false)

        for kind <- Aggregate.kinds() do
          field = if kind in [:count, :exists], do: nil, else: :hectares
          expected = Aggregate.compute(kind, field, rows, Paddock, shape(kind))
          actual = Ramal.aggregate!(Paddock, kind, field, authorize?: false)

          assert close?(actual, expected),
                 "#{kind} gave #{inspect(actual)}, expected #{inspect(expected)}"
        end
      end)

      :ok = Ramal.discard(branch)
    end
  end

  # `Ramal.aggregate/4` answers `:first` as `Ash.first/3` does, with the first row's value even when it is nil.
  defp shape(:first), do: [include_nil?: true]
  defp shape(_kind), do: []

  # Floats are added in a different order on the two paths.
  defp close?(a, b) when is_float(a) and is_float(b), do: abs(a - b) <= 1.0e-6 * max(1.0, abs(b))
  defp close?(a, b), do: a == b
end
