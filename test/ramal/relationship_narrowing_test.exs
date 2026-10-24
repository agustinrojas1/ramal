defmodule Ramal.RelationshipNarrowingTest do
  # A filter through a belongs_to or has_one the branch changed keeps a rewritten form in the data-layer query, so the
  # database returns fewer rows (ADR 0047). The answers are those of ADR 0025; what changes is `base_rows`.
  #
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query

  alias Ramal.Preparation.Related

  setup do
    start_supervised!(Ramal.Supervisor)
    seeds = Seeds.seed!()

    # Five more paddocks with one herd each, so the unchanged part of the table is bigger than the changed one.
    extra =
      for n <- 1..5 do
        paddock = Ash.create!(Paddock, %{name: "P#{n}", capacity_head: 10}, authorize?: false)

        herd =
          Ash.create!(Herd, %{name: "H#{n}", head: n, paddock_id: paddock.id}, authorize?: false)

        {n, %{paddock: paddock, herd: herd}}
      end

    {:ok, branch} = Ramal.branch(Farm)
    {:ok, Map.merge(seeds, %{branch: branch, extra: Map.new(extra)})}
  end

  defp names(query),
    do: query |> Ash.read!(authorize?: false) |> Enum.map(& &1.name) |> Enum.sort()

  # The names the query returns and the number of base rows the data layer gave the patch for it.
  defp read(query, resource \\ Herd) do
    handler = "narrowing-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:ramal, :read, :patch],
      fn
        _event, measurements, %{resource: ^resource}, _config ->
          send(test, {:patched, measurements.base_rows})

        _event, _measurements, _metadata, _config ->
          :ok
      end,
      nil
    )

    try do
      names = names(query)
      assert_receive {:patched, base_rows}
      {names, base_rows}
    after
      :telemetry.detach(handler)
    end
  end

  test "an unchanged paddock's herds are narrowed by the database", %{branch: branch, paddocks: p} do
    Ramal.run!(branch, fn ->
      Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)

      # 9 herds in the base. Without the rewrite the database returns all of them.
      assert read(Ash.Query.filter(Herd, paddock.name == "L18")) == {["R9"], 1}
      assert read(Ash.Query.filter(Herd, paddock.name == "P2")) == {["H2"], 1}
    end)
  end

  test "a paddock renamed into the filter brings its herds in", %{
    branch: branch,
    paddocks: p,
    extra: extra
  } do
    Ramal.run!(branch, fn ->
      # The name is free first: a branch refuses a second paddock with it, as the database would.
      Ash.update!(p.l07, %{name: "OLD07"}, authorize?: false)
      Ash.update!(extra[1].paddock, %{name: "L07"}, authorize?: false)

      assert read(Ash.Query.filter(Herd, paddock.name == "L07")) == {["H1"], 1}
    end)
  end

  test "a paddock renamed out of the filter takes its herds out", %{branch: branch, paddocks: p} do
    Ramal.run!(branch, fn ->
      Ash.update!(p.l07, %{name: "ELSEWHERE"}, authorize?: false)

      assert read(Ash.Query.filter(Herd, paddock.name == "L07")) == {[], 0}
      assert read(Ash.Query.filter(Herd, paddock.name == "ELSEWHERE")) == {["R7", "R8"], 2}
    end)

    # Outside the branch the base is as it was.
    assert names(Ash.Query.filter(Herd, paddock.name == "L07")) == ["R7", "R8"]
  end

  test "a destroyed paddock matches only what a missing paddock matches", %{
    branch: branch,
    paddocks: p
  } do
    {:ok, loose} = Ash.create(Herd, %{name: "LOOSE", head: 1}, authorize?: false)

    Ramal.run!(branch, fn ->
      Ash.destroy!(p.l07, authorize?: false)

      assert read(Ash.Query.filter(Herd, paddock.name == "L07")) == {[], 0}
      # The LEFT JOIN of a destroyed paddock gives nulls, and so does a herd without one.
      assert {names, _rows} = read(Ash.Query.filter(Herd, is_nil(paddock.name)))
      assert names == ["LOOSE", "R7", "R8"]
      assert loose.paddock_id == nil
    end)
  end

  test "a paddock created in the branch and linked to a herd", %{branch: branch, extra: extra} do
    Ramal.run!(branch, fn ->
      new = Ash.create!(Paddock, %{name: "NEW", capacity_head: 10}, authorize?: false)
      Ash.update!(extra[3].herd, %{paddock_id: new.id}, authorize?: false)
      other = Ash.create!(Paddock, %{name: "L19", capacity_head: 10}, authorize?: false)
      Ash.create!(Herd, %{name: "CREATED", head: 1, paddock_id: other.id}, authorize?: false)

      assert read(Ash.Query.filter(Herd, paddock.name == "NEW")) == {["H3"], 0}
      assert {["CREATED"], _rows} = read(Ash.Query.filter(Herd, paddock.name == "L19"))
      assert {["R9"], _rows} = read(Ash.Query.filter(Herd, paddock.name == "L18"))
      assert {[], _rows} = read(Ash.Query.filter(Herd, paddock.name == "P3"))
    end)
  end

  describe "and, or and not" do
    test "an and or an or of leaves is narrowed and answers as before", %{
      branch: branch,
      paddocks: p,
      extra: extra
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)
        Ash.update!(extra[2].paddock, %{name: "Q2"}, authorize?: false)

        assert read(Ash.Query.filter(Herd, paddock.name == "RENAMED" and head > 30)) ==
                 {["R8"], 1}

        assert read(Ash.Query.filter(Herd, paddock.name == "Q2" or name == "H4")) ==
                 {["H2", "H4"], 2}

        assert read(Ash.Query.filter(Herd, paddock.name == "RENAMED" or paddock.name == "Q2")) ==
                 {["H2", "R7", "R8"], 3}

        assert read(Ash.Query.filter(Herd, paddock.name in ["RENAMED", "P5"])) ==
                 {["H5", "R7", "R8"], 3}
      end)
    end

    test "a not over the changed relationship is not narrowed and still answers right", %{
      branch: branch,
      paddocks: p,
      extra: extra
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)
        Ash.update!(extra[1].paddock, %{name: "L07"}, authorize?: false)

        query = Ash.Query.filter(Herd, not (paddock.name == "L07"))
        assert {["H2", "H3", "H4", "H5", "R7", "R8", "R9"], 8} = read(query)

        assert {:ok, plan} = Related.plan(query, branch.id)
        assert plan.data_layer == plan.kept

        both = Ash.Query.filter(Herd, not (paddock.name == "L07") and paddock.name == "RENAMED")
        assert {["R7", "R8"], _rows} = read(both)
      end)
    end

    test "a not over a leaf that does not reach the changed relationship keeps the narrowing", %{
      branch: branch,
      paddocks: p
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)

        query = Ash.Query.filter(Herd, paddock.name == "L18" or not (head > 100))
        assert {_names, _rows} = read(query)
        assert {:ok, plan} = Related.plan(query, branch.id)
        assert plan.data_layer != plan.kept
      end)
    end

    test "a leaf that mixes the related row with the herd's own attributes is left to Elixir", %{
      branch: branch,
      paddocks: p
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: "R7"}, authorize?: false)

        query = Ash.Query.filter(Herd, paddock.name == name)
        assert {["R7"], _rows} = read(query)
        assert {:ok, plan} = Related.plan(query, branch.id)
        assert plan.data_layer == plan.kept
      end)
    end
  end

  describe "foreign keys that are nil" do
    test "a herd without a paddock is not matched by the paddock's name, and is by is_nil", %{
      branch: branch,
      paddocks: p
    } do
      Ash.create!(Herd, %{name: "LOOSE", head: 1}, authorize?: false)

      Ramal.run!(branch, fn ->
        Ash.update!(p.l07, %{name: nil_name()}, authorize?: false)

        assert {names, _rows} = read(Ash.Query.filter(Herd, paddock.name == "L18"))
        assert names == ["R9"]

        assert {names, _rows} = read(Ash.Query.filter(Herd, is_nil(paddock.name)))
        assert names == ["LOOSE"]

        assert {names, _rows} =
                 read(Ash.Query.filter(Herd, is_nil(paddock.name) or paddock.name == "L18"))

        assert names == ["LOOSE", "R9"]
      end)
    end

    # The name is required, so "no name" is a name nothing matches.
    defp nil_name, do: "NOBODY"
  end

  describe "a has_one" do
    test "keeps the database's judgement of the unchanged and adds the branch's candidates", %{
      branch: branch,
      extra: extra
    } do
      Ramal.run!(branch, fn ->
        Ash.update!(extra[1].herd, %{name: "RENAMED"}, authorize?: false)
        Ash.update!(extra[2].herd, %{name: "H4"}, authorize?: false)

        assert read(Ash.Query.filter(Paddock, first_herd.name == "RENAMED"), Paddock) ==
                 {["P1"], 2}

        assert {[], _rows} = read(Ash.Query.filter(Paddock, first_herd.name == "H1"), Paddock)

        assert {["P2", "P4"], 3} =
                 read(Ash.Query.filter(Paddock, first_herd.name == "H4"), Paddock)

        assert {["L18"], 3} = read(Ash.Query.filter(Paddock, first_herd.name == "R9"), Paddock)
      end)
    end
  end

  describe "a has_one leaf that a missing related row satisfies" do
    test "is left to Elixir, because sources that lost their row start to match", %{
      branch: branch,
      herds: h,
      extra: extra
    } do
      Ramal.run!(branch, fn ->
        # L07 has two herds in the seeds; one is enough for a has_one that is not `from_many?`.
        Ash.destroy!(h.r8, authorize?: false)
        Ash.destroy!(extra[1].herd, authorize?: false)
        Ash.destroy!(extra[3].herd, authorize?: false)
        Ash.update!(extra[2].herd, %{paddock_id: extra[3].paddock.id}, authorize?: false)

        query = Ash.Query.filter(Paddock, is_nil(first_herd.name))
        {names, _rows} = read(query, Paddock)

        # P1 lost its herd by a destroy, P2 by a move; P3 got P2's herd and does not match.
        assert "P1" in names
        assert "P2" in names
        refute "P3" in names
        assert {:ok, plan} = Related.plan(query, branch.id)
        assert plan.data_layer == plan.kept
      end)
    end
  end

  test "a narrowed read answers what the same filter gives over every herd of the branch", %{
    branch: branch,
    paddocks: p,
    herds: h,
    extra: extra
  } do
    Ash.create!(Herd, %{name: "LOOSE", head: 1}, authorize?: false)

    Ramal.run!(branch, fn ->
      # Names swap through a free one, as they must on the database.
      Ash.update!(p.l18, %{name: "M18"}, authorize?: false)
      Ash.update!(p.l07, %{name: "L18"}, authorize?: false)
      Ash.update!(extra[1].paddock, %{name: "L07"}, authorize?: false)
      Ash.destroy!(extra[2].paddock, authorize?: false)
      Ash.update!(h.r9, %{paddock_id: extra[4].paddock.id}, authorize?: false)
      new = Ash.create!(Paddock, %{name: "N07", capacity_head: 1}, authorize?: false)
      Ash.create!(Herd, %{name: "NEWH", head: 1, paddock_id: new.id}, authorize?: false)

      # Every herd with its paddock, as the branch sees them; the predicates are the filters written in Elixir.
      herds = Ash.read!(Ash.Query.load(Herd, :paddock), authorize?: false)
      name = fn herd -> herd.paddock && herd.paddock.name end

      cases = [
        {Ash.Query.filter(Herd, paddock.name == "L07"), &(name.(&1) == "L07")},
        {Ash.Query.filter(Herd, paddock.name == "L18" or paddock.name == "L07"),
         &(name.(&1) in ["L18", "L07"])},
        {Ash.Query.filter(Herd, paddock.name == "L18" and head > 10),
         &(name.(&1) == "L18" and &1.head > 10)},
        {Ash.Query.filter(Herd, is_nil(paddock.name)), &is_nil(name.(&1))},
        {Ash.Query.filter(Herd, not (paddock.name == "L07")),
         &(not is_nil(name.(&1)) and name.(&1) != "L07")},
        {Ash.Query.filter(Herd, not is_nil(paddock.name)), &(not is_nil(name.(&1)))},
        {Ash.Query.filter(Herd, paddock.name == "L07" or is_nil(paddock.name)),
         &(is_nil(name.(&1)) or name.(&1) == "L07")},
        {Ash.Query.filter(Herd, paddock.name in ["P4", "P5", "L18"]),
         &(name.(&1) in ["P4", "P5", "L18"])}
      ]

      for {query, predicate} <- cases do
        expected = herds |> Enum.filter(predicate) |> Enum.map(& &1.name) |> Enum.sort()
        assert names(query) == expected, inspect(query.filter)
      end
    end)
  end

  test "is transparent outside a branch and without changes to the related resource", %{
    branch: branch,
    herds: h
  } do
    # No branch is current: the preparation leaves the query alone and nothing is patched.
    assert names(Ash.Query.filter(Herd, paddock.name == "L07")) == ["R7", "R8"]

    Ramal.run!(branch, fn ->
      # Only herds changed: the filter goes to the database whole, nothing to rewrite.
      Ash.update!(h.r9, %{head: 99}, authorize?: false)
      query = Ash.Query.filter(Herd, paddock.name == "L07")
      assert {["R7", "R8"], _rows} = read(query)
      assert Related.plan(query, branch.id) == {:ok, :safe}
    end)
  end

  test "the rows the branch changed on the source side are still patched", %{
    branch: branch,
    paddocks: p,
    herds: h,
    extra: extra
  } do
    Ramal.run!(branch, fn ->
      Ash.update!(p.l07, %{name: "RENAMED"}, authorize?: false)
      # R9 moves into the renamed paddock, H1 out of the filter, a new herd joins.
      Ash.update!(h.r9, %{paddock_id: p.l07.id}, authorize?: false)
      Ash.update!(extra[1].herd, %{paddock_id: p.l18.id}, authorize?: false)
      Ash.create!(Herd, %{name: "NEWH", head: 1, paddock_id: p.l07.id}, authorize?: false)
      Ash.destroy!(h.r8, authorize?: false)

      assert {["NEWH", "R7", "R9"], _rows} =
               read(Ash.Query.filter(Herd, paddock.name == "RENAMED"))

      assert {["H1"], _rows} = read(Ash.Query.filter(Herd, paddock.name == "L18"))
    end)
  end
end
