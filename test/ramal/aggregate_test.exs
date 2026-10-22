defmodule Ramal.AggregateTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Aggregate
  alias Ramal.Test.Other.Note

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
end
