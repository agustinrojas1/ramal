defmodule Ramal.AggregateTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Aggregate
  alias Ramal.Test.Ets
  alias Ramal.Test.Other.{Note, Slot}

  doctest Ramal.Aggregate

  describe "Ramal.Aggregate.compute/4" do
    test "skips nil values and gives nil for no values, like SQL" do
      records = [%{head: 30}, %{head: nil}, %{head: 12}]

      assert Aggregate.compute(:sum, :head, records, Herd) == 42
      assert Aggregate.compute(:avg, :head, records, Herd) == 21.0
      assert Aggregate.compute(:min, :head, records, Herd) == 12
      assert Aggregate.compute(:count, nil, records, Herd) == 3

      for kind <- [:sum, :avg, :min, :max] do
        assert Aggregate.compute(kind, :head, [], Herd) == nil
        assert Aggregate.compute(kind, :head, [%{head: nil}], Herd) == nil
      end

      assert Aggregate.compute(:exists, nil, [], Herd) == false
      assert Aggregate.compute(:count, nil, [], Herd) == 0
    end

    test "sums decimals as decimals, including integers mixed in" do
      records = [%{score: Decimal.new("1.10")}, %{score: Decimal.new("2.20")}]
      assert Aggregate.compute(:sum, :score, records, Note) == Decimal.new("3.30")
      assert Aggregate.compute(:avg, :score, records, Note) == 1.65
    end

    test "orders min and max by the type of the field" do
      dates = [%{scheduled_on: ~D[2026-03-01]}, %{scheduled_on: ~D[2025-12-31]}]
      assert Aggregate.compute(:min, :scheduled_on, dates, Note) == ~D[2025-12-31]
      assert Aggregate.compute(:max, :scheduled_on, dates, Note) == ~D[2026-03-01]

      decimals = [%{score: Decimal.new("10")}, %{score: Decimal.new("9.5")}]
      assert Aggregate.compute(:max, :score, decimals, Note) == Decimal.new("10")

      texts = [%{text: "b"}, %{text: "a"}]
      assert Aggregate.compute(:min, :text, texts, Note) == "a"
    end

    test "refuses an unknown kind and a field that is not an attribute" do
      assert_raise ArgumentError, ~r/unknown aggregate kind :median/, fn ->
        Aggregate.compute(:median, :head, [], Herd)
      end

      assert_raise ArgumentError, ~r/not an attribute/, fn ->
        Aggregate.compute(:sum, :nope, [], Herd)
      end

      assert_raise ArgumentError, ~r/not an attribute/, fn ->
        Aggregate.compute(:sum, nil, [], Herd)
      end
    end
  end

  describe "Ramal.Aggregate.combine/5" do
    test "an empty overlay leaves the database's answer, an empty base leaves the branch's" do
      for {kind, base} <- [count: 4, exists: true, sum: 10, min: 2, max: 9, avg: {10, 4}] do
        assert Aggregate.combine(kind, :head, Herd, base, []) ==
                 Aggregate.combine(kind, :head, Herd, base, [])
      end

      assert Aggregate.combine(:count, nil, Herd, 4, []) == 4
      assert Aggregate.combine(:sum, :head, Herd, 10, []) == 10
      assert Aggregate.combine(:avg, :head, Herd, {10, 4}, []) == 2.5

      rows = [%{head: 5}, %{head: 7}]
      assert Aggregate.combine(:count, nil, Herd, 0, rows) == 2
      assert Aggregate.combine(:sum, :head, Herd, nil, rows) == 12
      assert Aggregate.combine(:min, :head, Herd, nil, rows) == 5
      assert Aggregate.combine(:max, :head, Herd, nil, rows) == 7
      assert Aggregate.combine(:avg, :head, Herd, {nil, 0}, rows) == 6.0
      assert Aggregate.combine(:exists, nil, Herd, false, rows)
    end

    test "nothing on either side is nil, count zero and exists false" do
      assert Aggregate.combine(:count, nil, Herd, 0, []) == 0
      refute Aggregate.combine(:exists, nil, Herd, false, [])

      for kind <- [:sum, :min, :max] do
        assert Aggregate.combine(kind, :head, Herd, nil, []) == nil
        assert Aggregate.combine(kind, :head, Herd, nil, [%{head: nil}]) == nil
      end

      assert Aggregate.combine(:avg, :head, Herd, {nil, 0}, [%{head: nil}]) == nil
    end

    test "nil values in the branch's rows are skipped, and do not count towards the average" do
      rows = [%{head: nil}, %{head: 8}]
      assert Aggregate.combine(:count, nil, Herd, 1, rows) == 3
      assert Aggregate.combine(:sum, :head, Herd, 2, rows) == 10
      assert Aggregate.combine(:avg, :head, Herd, {2, 1}, rows) == 5.0
    end

    test "decimals add as decimals and average to a float" do
      rows = [%{score: Decimal.new("1.10")}, %{score: nil}]
      base = Decimal.new("2.20")

      assert Aggregate.combine(:sum, :score, Note, base, rows) == Decimal.new("3.30")
      assert Aggregate.combine(:max, :score, Note, base, rows) == Decimal.new("2.20")
      assert Aggregate.combine(:min, :score, Note, base, rows) == Decimal.new("1.10")
      assert Aggregate.combine(:avg, :score, Note, {base, 1}, rows) == 1.65
    end

    test "refuses what compute/4 refuses" do
      assert_raise ArgumentError, ~r/not an attribute/, fn ->
        Aggregate.combine(:sum, :nope, Herd, 1, [])
      end
    end
  end

  describe "Ramal.aggregate/4" do
    setup do
      start_supervised!(Ramal.Supervisor)
      seeds = Seeds.seed!()
      {:ok, branch} = Ramal.branch(Farm)
      {:ok, Map.merge(seeds, %{branch: branch})}
    end

    test "outside a branch it is the data layer's answer" do
      assert Ramal.aggregate(Herd, :count, nil, authorize?: false) == {:ok, 3}
      assert Ramal.aggregate(Herd, :sum, :head, authorize?: false) == {:ok, 90}
      assert Ramal.aggregate(Herd, :max, :head, authorize?: false) == {:ok, 35}
      assert Ramal.aggregate(Herd, :min, :head, authorize?: false) == {:ok, 25}
      assert Ramal.aggregate(Herd, :exists, nil, authorize?: false) == {:ok, true}
      assert {:ok, avg} = Ramal.aggregate(Herd, :avg, :head, authorize?: false)
      assert_in_delta avg, 30.0, 0.0001
    end

    test "inside a branch it sees creates, updates and destroys the data layer's aggregate does not",
         %{
           branch: branch,
           herds: herds
         } do
      Ramal.run!(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        Ash.destroy!(herds.r9, authorize?: false)

        # 31 + 35 + 5; the base still says 30 + 35 + 25.
        assert Ramal.aggregate!(Herd, :sum, :head, authorize?: false) == 71
        assert Ramal.aggregate!(Herd, :count, nil, authorize?: false) == 3
        assert Ramal.aggregate!(Herd, :min, :head, authorize?: false) == 5
        assert Ramal.aggregate!(Herd, :max, :head, authorize?: false) == 35
        assert Ash.sum!(Herd, :head, authorize?: false) == 90
      end)

      assert Ramal.aggregate!(Herd, :sum, :head, authorize?: false) == 90
    end

    test "honours the filter of the query", %{branch: branch, paddocks: paddocks} do
      query = Ash.Query.filter(Herd, paddock_id == ^paddocks.l18.id)

      Ramal.run!(branch, fn ->
        Ash.create!(Herd, %{name: "R10", head: 5, paddock_id: paddocks.l18.id}, authorize?: false)
        Ash.create!(Herd, %{name: "R11", head: 7, paddock_id: paddocks.l07.id}, authorize?: false)

        assert Ramal.aggregate!(query, :sum, :head, authorize?: false) == 30
        assert Ramal.aggregate!(query, :count, nil, authorize?: false) == 2
      end)
    end

    test "exists is true for a row only the branch has", %{branch: branch, herds: herds} do
      query = Ash.Query.filter(Herd, name == "R10")

      Ramal.run!(branch, fn ->
        refute Ramal.aggregate!(query, :exists, nil, authorize?: false)
        Ash.create!(Herd, %{name: "R10", head: 5}, authorize?: false)
        assert Ramal.aggregate!(query, :exists, nil, authorize?: false)
        Ash.destroy!(herds.r7, authorize?: false)

        refute Ramal.aggregate!(Ash.Query.filter(Herd, name == "R7"), :exists, nil,
                 authorize?: false
               )
      end)
    end

    test "policies still apply to the read", %{branch: branch} do
      Ramal.run!(branch, fn ->
        assert {:ok, 3} = Ramal.aggregate(Herd, :count, nil, actor: %{role: :member})
      end)
    end

    test "refuses a field that is not an attribute, in and out of a branch", %{branch: branch} do
      assert_raise ArgumentError, ~r/not an attribute/, fn ->
        Ramal.aggregate(Herd, :sum, :nope, authorize?: false)
      end

      Ramal.run!(branch, fn ->
        assert_raise ArgumentError, ~r/not an attribute/, fn ->
          Ramal.aggregate(Herd, :sum, :nope, authorize?: false)
        end
      end)
    end

    test "returns the read's error instead of raising", %{branch: branch} do
      Ramal.run!(branch, fn ->
        query = Ash.Query.add_error(Ash.Query.new(Herd), "the query is broken")

        assert {:error, %{errors: [_ | _]}} =
                 Ramal.aggregate(query, :count, nil, authorize?: false)
      end)
    end

    test "refuses an unknown kind" do
      assert_raise ArgumentError, ~r/unknown aggregate kind/, fn ->
        Ramal.aggregate(Herd, :median, :head)
      end
    end
  end

  describe "Ramal.aggregate/4 reads only what the overlay touches" do
    setup do
      start_supervised!(Ramal.Supervisor)
      seeds = Seeds.seed!()
      {:ok, branch} = Ramal.branch(Farm)
      {:ok, Map.merge(seeds, %{branch: branch})}
    end

    test "rows the branch only aggregated are not fingerprinted", %{branch: branch, herds: herds} do
      Ramal.run!(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        assert Ramal.aggregate!(Herd, :sum, :head, authorize?: false) == 91
      end)

      {:ok, stored} = Ramal.get(branch.id)
      keys = for {{Herd, key}, _} <- stored.base, do: key
      # the update read R7 to write it; R8 and R9 were only counted by the database
      assert keys == [herds.r7.id]
    end

    test "a limit, an offset or a distinct is answered over the rows that come first", %{
      branch: branch,
      herds: herds
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(herds.r7, %{head: 99}, authorize?: false)

        sorted = Ash.Query.sort(Herd, head: :desc)
        assert Ramal.aggregate!(Ash.Query.limit(sorted, 2), :sum, :head, authorize?: false) == 134
        assert Ramal.aggregate!(Ash.Query.limit(sorted, 2), :count, nil, authorize?: false) == 2

        assert Ramal.aggregate!(Ash.Query.offset(sorted, 1), :sum, :head, authorize?: false) ==
                 60
      end)
    end

    test "a row that stops matching the filter, or starts to, moves between the two parts", %{
      branch: branch,
      herds: herds
    } do
      big = Ash.Query.filter(Herd, head >= 30)

      Ramal.run!(branch, fn ->
        # R7 leaves the filter, R9 enters it, R8 is untouched.
        Ash.update!(herds.r7, %{head: 10}, authorize?: false)
        Ash.update!(herds.r9, %{head: 50}, authorize?: false)

        assert Ramal.aggregate!(big, :count, nil, authorize?: false) == 2
        assert Ramal.aggregate!(big, :sum, :head, authorize?: false) == 85
        assert Ramal.aggregate!(big, :min, :head, authorize?: false) == 35
        assert Ramal.aggregate!(big, :max, :head, authorize?: false) == 50
        assert_in_delta Ramal.aggregate!(big, :avg, :head, authorize?: false), 42.5, 0.0001
      end)
    end

    test "an empty table and a branch that destroyed everything", %{branch: branch, herds: herds} do
      Ramal.run!(branch, fn ->
        for herd <- Map.values(herds), do: Ash.destroy!(herd, authorize?: false)

        assert Ramal.aggregate!(Herd, :count, nil, authorize?: false) == 0
        refute Ramal.aggregate!(Herd, :exists, nil, authorize?: false)

        for kind <- [:sum, :min, :max, :avg] do
          assert Ramal.aggregate!(Herd, kind, :head, authorize?: false) == nil
        end
      end)
    end

    test "policies filter the database's part too", %{branch: branch, herds: herds} do
      Ramal.run!(branch, fn ->
        Ash.update!(herds.r7, %{head: 31}, authorize?: false)
        # the same answer as the read-based one for an actor the policies narrow down
        {:ok, rows} = Ash.read(Herd, actor: %{role: :member})
        expected = Aggregate.compute(:sum, :head, rows, Herd)
        assert Ramal.aggregate!(Herd, :sum, :head, actor: %{role: :member}) == expected
      end)
    end
  end

  describe "Ramal.aggregate/4 with a composite primary key" do
    setup do
      start_supervised!(Ramal.Supervisor)
      on_exit(fn -> Ets.reset(Slot) end)

      for {day, bay, load, weight} <- [
            {~D[2026-01-01], "a", 10, "1.5"},
            {~D[2026-01-01], "b", 20, "2.5"},
            {~D[2026-01-02], "a", 30, nil}
          ] do
        Ash.create!(
          Slot,
          %{day: day, bay: bay, load: load, weight: weight && Decimal.new(weight)},
          authorize?: false
        )
      end

      {:ok, branch} = Ramal.branch(Ramal.Test.Other)
      {:ok, branch: branch}
    end

    test "the overlay's keys are matched as tuples, and every kind agrees with the read", %{
      branch: branch
    } do
      Ramal.run!(branch, fn ->
        Slot |> Ash.get!(%{day: ~D[2026-01-01], bay: "a"}) |> Ash.update!(%{load: 15})
        Slot |> Ash.get!(%{day: ~D[2026-01-02], bay: "a"}) |> Ash.destroy!()
        Ash.create!(Slot, %{day: ~D[2026-01-03], bay: "z", load: 5, weight: Decimal.new("0.5")})

        {:ok, rows} = Ash.read(Slot)

        for kind <- Aggregate.kinds(), field <- [:load, :weight] do
          expected = Aggregate.compute(kind, field, rows, Slot)
          actual = Ramal.aggregate!(Slot, kind, field)

          assert same?(actual, expected),
                 "#{kind} of #{field}: #{inspect(actual)} != #{inspect(expected)}"
        end

        assert Ramal.aggregate!(Slot, :count) == 3
        assert Ramal.aggregate!(Slot, :sum, :load) == 40
        assert Ramal.aggregate!(Slot, :sum, :weight) == Decimal.new("4.5")
      end)
    end
  end

  defp same?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp same?(a, b) when is_float(a) and is_float(b), do: abs(a - b) < 1.0e-9
  defp same?(a, b), do: a == b
end
