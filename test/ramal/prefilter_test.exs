defmodule Ramal.PrefilterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Ash.Query

  alias Ash.Filter.Runtime
  alias Ash.Query.{BooleanExpression, Not, Operator, Ref}
  alias Ash.Resource.Info
  alias Ramal.Prefilter
  alias Ramal.Test.Farm
  alias Ramal.Test.Farm.Herd

  doctest Ramal.Prefilter

  defp herd(attrs),
    do: struct(Herd, Map.merge(%{id: Ash.UUID.generate(), name: "a", head: 1}, Map.new(attrs)))

  defp plan(query), do: Prefilter.compile(query.filter)

  defp ref(name),
    do: %Ref{
      attribute: Info.attribute(Herd, name),
      relationship_path: [],
      resource: Herd
    }

  describe "compile/1" do
    test "a query with no filter has no plan, so every record passes" do
      assert Prefilter.compile(Ash.Query.new(Herd).filter) == nil
      assert Prefilter.possible?(nil, herd([]))
    end

    test "turns comparisons of an attribute with a literal into data" do
      assert plan(Ash.Query.filter(Herd, head > 3)) == {:compare, :>, :head, 3}
      assert plan(Ash.Query.filter(Herd, name == "R7")) == {:compare, :==, :name, "R7"}
      assert plan(Ash.Query.filter(Herd, head != 3)) == {:compare, :!=, :head, 3}
      assert plan(Ash.Query.filter(Herd, is_nil(name))) == {:nil?, :name, true}
      assert {:in, :head, :integer, %MapSet{}} = plan(Ash.Query.filter(Herd, head in [1, 2]))
    end

    test "keeps the shape of and, or and not" do
      assert plan(Ash.Query.filter(Herd, head > 3 and not (name == "a"))) ==
               {:and, [{:compare, :>, :head, 3}, {:not, {:compare, :==, :name, "a"}}]}

      assert plan(Ash.Query.filter(Herd, head > 3 or head < 1)) ==
               {:or, [{:compare, :>, :head, 3}, {:compare, :<, :head, 1}]}
    end

    test "leaves what it does not understand to the runtime" do
      # a relationship path, a function, a value that is not a plain binary, integer or atom, and a ref on both sides
      assert plan(Ash.Query.filter(Herd, paddock.name == "L07")) == :unknown
      assert plan(Ash.Query.filter(Herd, contains(name, "R"))) == :unknown
      assert plan(Ash.Query.filter(Herd, inserted_at > ^~U[2026-01-01 00:00:00Z])) == :unknown
      assert plan(Ash.Query.filter(Herd, head == paddock_id)) == :unknown

      mixed = %Operator.In{left: ref(:head), right: MapSet.new([1, "two"])}
      assert Prefilter.compile(%Ash.Filter{resource: Herd, expression: mixed}) == :unknown
    end

    test "a filter that is only partly understood still rules out records through the part it understands" do
      plan = plan(Ash.Query.filter(Herd, head > 3 and contains(name, "R")))

      refute Prefilter.possible?(plan, herd(head: 2, name: "R7"))
      assert Prefilter.possible?(plan, herd(head: 4, name: "R7"))
      assert Prefilter.possible?(plan, herd(head: 4, name: "X"))
    end
  end

  describe "possible?/2" do
    test "is false for a record the filter rejects and true for one it accepts" do
      plan = plan(Ash.Query.filter(Herd, head > 3 and head <= 10))

      refute Prefilter.possible?(plan, herd(head: 3))
      refute Prefilter.possible?(plan, herd(head: 11))
      assert Prefilter.possible?(plan, herd(head: 4))
      assert Prefilter.possible?(plan, herd(head: 10))
    end

    test "is true when the value is nil or not loaded, because the runtime decides those" do
      plan = plan(Ash.Query.filter(Herd, head == 3))

      assert Prefilter.possible?(plan, herd(head: nil))
      assert Prefilter.possible?(plan, herd(head: %Ash.NotLoaded{type: :attribute, field: :head}))

      assert Prefilter.possible?(
               plan,
               herd(head: %Ash.ForbiddenField{field: :head, type: :attribute})
             )
    end

    test "is true when the value is of another kind than the literal" do
      assert Prefilter.possible?(plan(Ash.Query.filter(Herd, head == 3)), herd(head: "3"))
      assert Prefilter.possible?(plan(Ash.Query.filter(Herd, head == 3)), herd(head: 3.0))
    end

    test "negation only rules out what is surely true" do
      plan = plan(Ash.Query.filter(Herd, not (head == 3)))

      refute Prefilter.possible?(plan, herd(head: 3))
      assert Prefilter.possible?(plan, herd(head: 4))
      # not (nil == 3) is nil in Ash, which is not a match, but only the runtime may say so
      assert Prefilter.possible?(plan, herd(head: nil))
    end

    test "in and is_nil" do
      in_plan = plan(Ash.Query.filter(Herd, name in ["a", "b"]))
      refute Prefilter.possible?(in_plan, herd(name: "c"))
      assert Prefilter.possible?(in_plan, herd(name: "b"))
      assert Prefilter.possible?(in_plan, herd(name: nil))

      nil_plan = plan(Ash.Query.filter(Herd, is_nil(name)))
      refute Prefilter.possible?(nil_plan, herd(name: "a"))
      assert Prefilter.possible?(nil_plan, herd(name: nil))

      assert Prefilter.possible?(
               nil_plan,
               herd(name: %Ash.NotLoaded{type: :attribute, field: :name})
             )
    end
  end

  # The contract that matters: whatever Ash.Filter.Runtime accepts, the prefilter lets through.
  describe "against Ash.Filter.Runtime" do
    @heads [nil, -2, -1, 0, 1, 2, 3]
    @names [nil, "", "a", "b", "ab", "c"]

    defp operator(module, name, value) do
      {:ok, operator} = Operator.new(module, ref(name), value)
      operator
    end

    defp leaf do
      head = integer(-3..4)
      name = member_of(["", "a", "b", "ab", "c", "d"])

      one_of([
        gen all(module <- member_of(comparison_modules()), value <- head) do
          operator(module, :head, value)
        end,
        gen all(module <- member_of(comparison_modules()), value <- name) do
          operator(module, :name, value)
        end,
        gen all(values <- list_of(head, min_length: 1, max_length: 3)) do
          operator(Operator.In, :head, MapSet.new(values))
        end,
        gen all(values <- list_of(name, min_length: 1, max_length: 3)) do
          operator(Operator.In, :name, MapSet.new(values))
        end,
        gen all(field <- member_of([:head, :name]), value <- boolean()) do
          operator(Operator.IsNil, field, value)
        end
      ])
    end

    defp comparison_modules do
      [
        Operator.Eq,
        Operator.NotEq,
        Operator.LessThan,
        Operator.GreaterThan,
        Operator.LessThanOrEqual,
        Operator.GreaterThanOrEqual
      ]
    end

    defp expression do
      tree(leaf(), fn child ->
        one_of([
          gen(
            all(
              left <- child,
              right <- child,
              op <- member_of([:and, :or]),
              do: BooleanExpression.new(op, left, right)
            )
          ),
          gen(all(inner <- child, do: Not.new(inner)))
        ])
      end)
    end

    property "never rules out a record the runtime accepts" do
      check all(
              expression <- expression(),
              head <- member_of(@heads),
              name <- member_of(@names),
              max_runs: 600
            ) do
        record = herd(head: head, name: name)
        filter = %Ash.Filter{resource: Herd, expression: expression}

        {:ok, matches} = Runtime.filter_matches(Farm, [record], filter)

        if matches != [] do
          assert Prefilter.possible?(Prefilter.compile(filter), record),
                 "the runtime accepts #{inspect(record, limit: 4)} for #{inspect(expression)} but the prefilter rules it out"
        end
      end
    end

    # Found by the property above (seed 61): Ash's runtime is not SQL's three-valued logic. `nil and false` is `nil`,
    # so `not (nil and false)` is `nil` there, not `true`, and `false or nil` is `nil` where `nil or false` is `false`.
    test "nil under not, and and or is told apart from false like the runtime does" do
      head_is_0 = operator(Operator.Eq, :head, 0)
      name_in_a = operator(Operator.In, :name, MapSet.new(["a"]))
      name_in_blank = operator(Operator.In, :name, MapSet.new([""]))
      name_is_a = operator(Operator.Eq, :name, "a")
      record = herd(head: nil, name: "")

      expression =
        Not.new(
          BooleanExpression.new(
            :or,
            Not.new(BooleanExpression.new(:and, head_is_0, name_in_a)),
            BooleanExpression.new(
              :and,
              name_in_blank,
              BooleanExpression.new(:or, head_is_0, name_is_a)
            )
          )
        )

      filter = %Ash.Filter{resource: Herd, expression: expression}

      assert {:ok, [_matched]} = Runtime.filter_matches(Farm, [record], filter)
      assert Prefilter.possible?(Prefilter.compile(filter), record)
    end

    test "a record whose filter is surely false is still ruled out when another term is unknown" do
      # `head > 3 and name == "a"`: the unknown (calculation-like) side cannot make a false side true
      plan = {:and, [:unknown, {:compare, :==, :name, "a"}]}

      refute Prefilter.possible?(plan, herd(name: "b"))
      assert Prefilter.possible?(plan, herd(name: "a"))
      refute Prefilter.possible?({:or, [{:compare, :==, :name, "a"}, false]}, herd(name: "b"))
    end

    property "does rule records out, so it is not vacuous" do
      check all(
              value <- integer(-3..4),
              head <- member_of(Enum.reject(@heads, &is_nil/1)),
              max_runs: 100
            ) do
        filter = Ash.Query.filter(Herd, head == ^value).filter
        assert Prefilter.possible?(Prefilter.compile(filter), herd(head: head)) == (head == value)
      end
    end
  end
end
