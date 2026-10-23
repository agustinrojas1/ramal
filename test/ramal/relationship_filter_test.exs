defmodule Ramal.RelationshipFilterTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Sort
  require Ash.Query

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()
    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch})}
  end

  defp names(query),
    do: query |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()

  test "a filter through a relationship the branch renamed follows the branch's rows", %{
    branch: branch,
    paddocks: p
  } do
    Ramal.run!(branch, fn ->
      Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)

      assert names(Herd |> Ash.Query.filter(paddock.name == "RENAMED")) == ["R7", "R8"]
      assert names(Herd |> Ash.Query.filter(paddock.name == "L07")) == []

      assert Ramal.aggregate(Herd |> Ash.Query.filter(paddock.name == "L07"), :count, nil,
               authorize?: false
             ) ==
               {:ok, 0}

      assert Ramal.aggregate(Herd |> Ash.Query.filter(paddock.name == "RENAMED"), :count, nil,
               authorize?: false
             ) ==
               {:ok, 2}
    end)

    # Outside the branch the base is untouched.
    assert names(Herd |> Ash.Query.filter(paddock.name == "L07")) == ["R7", "R8"]
  end

  describe "sorts through a relationship" do
    test "follow the branch's rows", %{branch: branch, paddocks: p} do
      Ramal.run!(branch, fn ->
        # L07 becomes "ZZ", so its herds move after L18's.
        Ash.update!(p.l07, %{name: "ZZ"}, authorize?: false)

        sorted =
          Herd
          |> Ash.Query.sort([{Ash.Sort.expr_sort(paddock.name, :string), :asc}, name: :asc])
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.name)

        assert sorted == ["R9", "R7", "R8"]

        limited =
          Herd
          |> Ash.Query.sort([{Ash.Sort.expr_sort(paddock.name, :string), :asc}, name: :asc])
          |> Ash.Query.limit(2)
          |> Ash.Query.offset(1)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.name)

        assert limited == ["R7", "R8"]
      end)
    end
  end

  describe "other shapes of filter" do
    test "or, not, exists and a kept conjunct next to a removed one", %{
      branch: branch,
      paddocks: p
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)

        assert names(Herd |> Ash.Query.filter(paddock.name == "L18" or name == "R7")) == [
                 "R7",
                 "R9"
               ]

        assert names(Herd |> Ash.Query.filter(paddock.name == "RENAMED" or paddock.name == "L18")) ==
                 ["R7", "R8", "R9"]

        assert names(Herd |> Ash.Query.filter(not (paddock.name == "L07"))) == ["R7", "R8", "R9"]
        assert names(Herd |> Ash.Query.filter(not (paddock.name == "RENAMED"))) == ["R9"]
        assert names(Herd |> Ash.Query.filter(exists(paddock, name == "RENAMED"))) == ["R7", "R8"]
        assert names(Herd |> Ash.Query.filter(exists(paddock, name == "L07"))) == []
        assert names(Herd |> Ash.Query.filter(head > 30 and paddock.name == "RENAMED")) == ["R8"]
        assert names(Herd |> Ash.Query.filter(head > 30 and paddock.name == "L07")) == []
      end)
    end

    test "a paddock created, destroyed or reassigned in the branch", %{
      branch: branch,
      paddocks: p,
      herds: h
    } do
      Ramal.run!(branch, fn ->
        new = Ash.create!(Paddock, %{name: "NEW", capacity_head: 10}, authorize?: false)
        Ash.update!(h.r9, %{paddock_id: new.id}, authorize?: false)
        Ash.destroy!(p.l07, authorize?: false)

        assert names(Herd |> Ash.Query.filter(paddock.name == "NEW")) == ["R9"]
        assert names(Herd |> Ash.Query.filter(paddock.name == "L18")) == []
        assert names(Herd |> Ash.Query.filter(paddock.name == "L07")) == []
        # The destroyed paddock's herds have no paddock, as a LEFT JOIN would say.
        assert names(Herd |> Ash.Query.filter(is_nil(paddock.name))) == ["R7", "R8"]
      end)
    end

    test "a filter through a has_many from the paddock's side", %{branch: branch, herds: h} do
      Ramal.run!(branch, fn ->
        Ash.update!(h.r9, %{name: "R9x"}, authorize?: false)

        assert Paddock
               |> Ash.Query.filter(exists(herds, name == "R9x"))
               |> Ash.read!(authorize?: false)
               |> Enum.map(& &1.name) == ["L18"]

        assert Paddock
               |> Ash.Query.filter(exists(herds, name == "R9"))
               |> Ash.read!(authorize?: false)
               |> Enum.map(& &1.name) == []
      end)
    end

    test "a query that selects some attributes", %{branch: branch, paddocks: p} do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)

        rows =
          Herd
          |> Ash.Query.select([:name])
          |> Ash.Query.filter(paddock.name == "RENAMED")
          |> Ash.read!(authorize?: false)

        assert rows |> Enum.map(& &1.name) |> Enum.sort() == ["R7", "R8"]
      end)
    end

    test "is transparent when the branch changed nothing the filter reaches", %{
      branch: branch,
      herds: h
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(h.r7, %{head: 31}, authorize?: false)
        assert names(Herd |> Ash.Query.filter(paddock.name == "L07")) == ["R7", "R8"]
      end)
    end
  end
end

defmodule Ramal.RelationshipFilterPropertyTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false
  use ExUnitProperties

  require Ash.Expr
  require Ash.Query
  require Ash.Sort

  # The exact answer is computed on a plain model of the two tables: paddocks (id, name) and herds (id, name, head,
  # paddock id). No null appears in it, so the database's three-valued logic and the runtime's agree.
  @names ["a", "b", "c"]

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, Seeds.seed!()}
  end

  defp operation do
    one_of([
      tuple({constant(:rename_paddock), integer(0..5), member_of(@names)}),
      tuple({constant(:create_paddock), member_of(@names)}),
      tuple({constant(:move_herd), integer(0..5), integer(0..5)}),
      tuple({constant(:create_herd), integer(0..60), integer(0..5)}),
      tuple({constant(:destroy_herd), integer(0..5)})
    ])
  end

  defp leaf do
    one_of([
      tuple({constant(:paddock_name), member_of(@names)}),
      tuple({constant(:paddock_exists), member_of(@names)}),
      tuple({constant(:head_at_least), integer(0..60)})
    ])
  end

  defp filter do
    tree =
      tree(leaf(), fn child ->
        one_of([
          tuple({constant(:and), child, child}),
          tuple({constant(:or), child, child}),
          tuple({constant(:not), child})
        ])
      end)

    one_of([constant(:none), tree])
  end

  defp expression({:paddock_name, name}), do: Ash.Expr.expr(paddock.name == ^name)
  defp expression({:paddock_exists, name}), do: Ash.Expr.expr(exists(paddock, name == ^name))
  defp expression({:head_at_least, head}), do: Ash.Expr.expr(head >= ^head)
  defp expression({:and, a, b}), do: Ash.Expr.expr(^expression(a) and ^expression(b))
  defp expression({:or, a, b}), do: Ash.Expr.expr(^expression(a) or ^expression(b))
  defp expression({:not, a}), do: Ash.Expr.expr(not (^expression(a)))

  defp matches?({:paddock_name, name}, herd, model), do: paddock_name(herd, model) == name
  defp matches?({:paddock_exists, name}, herd, model), do: paddock_name(herd, model) == name
  defp matches?({:head_at_least, head}, herd, _model), do: herd.head >= head

  defp matches?({:and, a, b}, herd, model),
    do: matches?(a, herd, model) and matches?(b, herd, model)

  defp matches?({:or, a, b}, herd, model),
    do: matches?(a, herd, model) or matches?(b, herd, model)

  defp matches?({:not, a}, herd, model), do: not matches?(a, herd, model)

  defp paddock_name(herd, model), do: Map.fetch!(model.paddocks, herd.paddock_id)

  defp pick(map, index) do
    keys = map |> Map.keys() |> Enum.sort()
    Enum.at(keys, rem(index, length(keys)))
  end

  defp apply_operation({:rename_paddock, index, name}, model) do
    id = pick(model.paddocks, index)
    Ash.update!(Ash.get!(Paddock, id, authorize?: false), %{name: name}, authorize?: false)
    put_in(model.paddocks[id], name)
  end

  defp apply_operation({:create_paddock, name}, model) do
    paddock = Ash.create!(Paddock, %{name: name, capacity_head: 10}, authorize?: false)
    put_in(model.paddocks[paddock.id], name)
  end

  defp apply_operation({:move_herd, herd_index, paddock_index}, model) do
    id = pick(model.herds, herd_index)
    paddock_id = pick(model.paddocks, paddock_index)

    Ash.update!(Ash.get!(Herd, id, authorize?: false), %{paddock_id: paddock_id},
      authorize?: false
    )

    put_in(model.herds[id].paddock_id, paddock_id)
  end

  defp apply_operation({:create_herd, head, paddock_index}, model) do
    paddock_id = pick(model.paddocks, paddock_index)
    name = "h#{System.unique_integer([:positive])}"
    herd = Ash.create!(Herd, %{name: name, head: head, paddock_id: paddock_id}, authorize?: false)
    put_in(model.herds[herd.id], %{name: name, head: head, paddock_id: paddock_id})
  end

  defp apply_operation({:destroy_herd, _index}, %{herds: herds} = model)
       when map_size(herds) <= 1,
       do: model

  defp apply_operation({:destroy_herd, index}, model) do
    id = pick(model.herds, index)
    Ash.destroy!(Ash.get!(Herd, id, authorize?: false), authorize?: false)
    update_in(model.herds, &Map.delete(&1, id))
  end

  property "filters, sorts and aggregates through a relationship give the exact answer", %{
    paddocks: paddocks,
    herds: herds
  } do
    start = %{
      paddocks: %{paddocks.l07.id => "a", paddocks.l18.id => "b"},
      herds:
        Map.new(
          Map.values(herds),
          &{&1.id, %{name: &1.name, head: &1.head, paddock_id: &1.paddock_id}}
        )
    }

    check all(
            operations <- list_of(operation(), max_length: 10),
            shape <- filter(),
            max_runs: 60
          ) do
      {:ok, branch} = Ramal.branch(Farm)

      Ramal.run!(branch, fn ->
        # The seeds' names are renamed first, so every run has a changed paddock and the names sort the same way in
        # the database and in the branch.
        model =
          Enum.reduce(start.paddocks, start, fn {id, name}, model ->
            Ash.update!(Ash.get!(Paddock, id, authorize?: false), %{name: name},
              authorize?: false
            )

            model
          end)

        model = Enum.reduce(operations, model, &apply_operation/2)
        query = if shape == :none, do: Herd, else: Ash.Query.filter(Herd, ^expression(shape))

        expected =
          model.herds
          |> Map.values()
          |> Enum.filter(&(shape == :none or matches?(shape, &1, model)))
          |> Enum.map(& &1.name)
          |> Enum.sort()

        assert query |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort() ==
                 expected

        assert Ramal.aggregate!(query, :count, nil, authorize?: false) == length(expected)

        # Sorted by the paddock's name, then by the herd's own.
        sorted =
          query
          |> Ash.Query.sort([{Ash.Sort.expr_sort(paddock.name, :string), :asc}, name: :asc])
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.name)

        expected_sorted =
          model.herds
          |> Map.values()
          |> Enum.filter(&(shape == :none or matches?(shape, &1, model)))
          |> Enum.sort_by(&{paddock_name(&1, model), &1.name})
          |> Enum.map(& &1.name)

        assert sorted == expected_sorted
      end)

      :ok = Ramal.discard(branch)
    end
  end
end
