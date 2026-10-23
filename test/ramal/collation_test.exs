defmodule Ramal.CollationTest do
  # Ramal.Supervisor is one per node and named, so these tests cannot run concurrently.
  use Ramal.DataCase, async: false

  require Ash.Query
  require Ash.Sort

  alias Ramal.Collation
  alias Ramal.Test.Capture.Counter
  alias Ramal.Test.Texts
  alias Ramal.Test.Texts.Tag

  # Text that tells the orders apart: case, accents, punctuation, a space, digits and a lone capital at the end.
  @names [
    "banana",
    "Apple",
    "cherry",
    "apple",
    "Banana",
    "Ápple",
    "éclair",
    "Zebra",
    "_under",
    "10",
    "9",
    "a b",
    "ab"
  ]

  # Byte order, which is what `C` means: digits, capitals, `_`, lowercase, then the accented letters by their bytes.
  @byte_order [
    "10",
    "9",
    "Apple",
    "Banana",
    "Zebra",
    "_under",
    "a b",
    "ab",
    "apple",
    "banana",
    "cherry",
    "Ápple",
    "éclair"
  ]

  # ICU's root collation (`und-x-icu`): punctuation before digits before letters, a letter before its capital, and an
  # accent after both.
  @icu_order [
    "_under",
    "10",
    "9",
    "a b",
    "ab",
    "apple",
    "Apple",
    "Ápple",
    "banana",
    "Banana",
    "cherry",
    "éclair",
    "Zebra"
  ]

  setup do
    start_supervised!(Ramal.Supervisor)
    {:ok, branch} = Ramal.branch(Texts)
    {:ok, branch: branch}
  end

  defp inside(branch, fun), do: Ramal.run!(branch, fun)

  defp attrs(name, rank), do: %{name: name, name_c: name, name_icu: name, label: name, rank: rank}

  # The first rows go to the database, the others are created in the branch, so the overlay touches the resource and
  # every read is sorted in Elixir. `rank` is unique, so a sort that ends with it is total.
  defp seed!(branch, names \\ @names, in_database \\ 6) do
    {base, branched} = names |> Enum.with_index() |> Enum.split(in_database)

    for {name, rank} <- base, do: Ash.create!(Tag, attrs(name, rank), authorize?: false)

    for {name, rank} <- branched do
      inside(branch, fn -> Ash.create!(Tag, attrs(name, rank), authorize?: false) end)
    end

    :ok
  end

  defp sorted(sort), do: Tag |> Ash.Query.sort(sort) |> Ash.read!(authorize?: false)
  defp ranks(sort), do: sort |> sorted() |> Enum.map(& &1.rank)
  defp column(sort, column), do: sort |> sorted() |> Enum.map(&Map.fetch!(&1, column))

  # A citext value is compared in lower case, and a database may return either case of two equal ones.
  defp text(%Ash.CiString{} = value), do: String.downcase(Ash.CiString.value(value))
  defp text(value), do: value

  # Reads in the branch, merges it and reads the database with the same sort: the order the branch showed is the order
  # the database gives the rows it received. Returns the ranks in that order.
  defp same_order_after_merge(branch, sort) do
    in_branch = inside(branch, fn -> ranks(sort) end)
    assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
    assert ranks(sort) == in_branch
    in_branch
  end

  describe "the branch orders text like the database" do
    for column <- [:name, :name_c, :name_icu, :label], direction <- [:asc, :desc] do
      test "#{column} #{direction}, after the merge", %{branch: branch} do
        seed!(branch)
        same_order_after_merge(branch, [{unquote(column), unquote(direction)}, rank: :asc])
      end
    end

    test "a column of the database's default collation", %{branch: branch} do
      seed!(branch, ["Banana", "apple", "cherry", "Date"], 2)
      names = inside(branch, fn -> column([name: :asc], :name) end)

      # The test database is created with en_US.UTF-8, like CI's; under another default this checks the byte order.
      %{rows: [[apple_first?]]} = TestRepo.query!("SELECT 'apple'::text < 'Banana'::text")

      if apple_first? do
        assert names == ["apple", "Banana", "cherry", "Date"]
      else
        assert names == ["Banana", "Date", "apple", "cherry"]
      end
    end

    test "a C column is in byte order", %{branch: branch} do
      seed!(branch)
      assert inside(branch, fn -> column([name_c: :asc], :name_c) end) == @byte_order

      assert inside(branch, fn -> column([name_c: :desc], :name_c) end) ==
               Enum.reverse(@byte_order)
    end

    test "an ICU column follows ICU's order, whatever the database's default is", %{
      branch: branch
    } do
      seed!(branch)
      assert inside(branch, fn -> column([name_icu: :asc], :name_icu) end) == @icu_order

      assert inside(branch, fn -> column([name_icu: :desc], :name_icu) end) ==
               Enum.reverse(@icu_order)
    end

    test "a citext column orders by the lower case text, and values equal to it tie", %{
      branch: branch
    } do
      seed!(branch)
      in_branch = same_order_after_merge(branch, label: :asc, rank: :desc)

      # apple (3) and Apple (1) are one value to citext, as are banana (0) and Banana (4): the second key, rank
      # descending, decides, so they sit next to each other in that order.
      pairs = Enum.chunk_every(in_branch, 2, 1, :discard)
      assert [3, 1] in pairs
      assert [4, 0] in pairs
    end

    test "an atom column is ordered as text", %{branch: branch} do
      for {kind, rank} <- Enum.with_index([:gamma, :alpha, :Delta, :Beta]) do
        inside(branch, fn -> Ash.create!(Tag, %{kind: kind, rank: rank}, authorize?: false) end)
      end

      in_branch = inside(branch, fn -> column([kind: :asc], :kind) end)
      assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
      assert column([kind: :asc], :kind) == in_branch
    end

    test "rows the branch updated and destroyed are sorted as they are now", %{branch: branch} do
      seed!(branch)
      [first | rest] = Tag |> Ash.Query.sort(rank: :asc) |> Ash.read!(authorize?: false)

      inside(branch, fn ->
        Ash.update!(first, %{name: "Mango", name_icu: "Mango"}, authorize?: false)
        Ash.destroy!(hd(rest), authorize?: false)
      end)

      same_order_after_merge(branch, name_icu: :asc, rank: :asc)
    end
  end

  describe "nils" do
    setup %{branch: branch} do
      seed!(branch, [nil, "b", nil, "B", "a", "A"], 3)
    end

    for direction <- [
          :asc,
          :desc,
          :asc_nils_first,
          :asc_nils_last,
          :desc_nils_first,
          :desc_nils_last
        ],
        column <- [:name, :name_c, :label] do
      test "#{column} #{direction} places them as the database does", %{branch: branch} do
        same_order_after_merge(branch, [{unquote(column), unquote(direction)}, rank: :asc])
      end
    end

    test "ascending puts them last and descending first", %{branch: branch} do
      assert inside(branch, fn -> ranks(name_icu: :asc, rank: :asc) end) |> Enum.take(-2) == [
               0,
               2
             ]

      assert inside(branch, fn -> ranks(name_icu: :desc, rank: :asc) end) |> Enum.take(2) == [
               0,
               2
             ]
    end
  end

  describe "several keys" do
    setup %{branch: branch} do
      seed!(branch, ["b", "a", "b", "a", "b", "a", "c"], 3)
    end

    test "a text key before a number breaks its ties with it", %{branch: branch} do
      assert inside(branch, fn -> ranks(name: :asc, rank: :desc) end) == [5, 3, 1, 4, 2, 0, 6]
      assert inside(branch, fn -> ranks(name_c: :desc, rank: :asc) end) == [6, 0, 2, 4, 1, 3, 5]
    end

    test "a number before a text key decides first", %{branch: branch} do
      assert inside(branch, fn -> ranks(rank: :desc, name: :asc) end) == [6, 5, 4, 3, 2, 1, 0]
    end

    test "a text key between two others", %{branch: branch} do
      assert inside(branch, fn -> ranks(name_icu: :asc, label: :desc, rank: :desc) end) ==
               [5, 3, 1, 4, 2, 0, 6]

      assert inside(branch, fn -> ranks(rank: :asc, name_icu: :desc, label: :asc) end) ==
               [0, 1, 2, 3, 4, 5, 6]
    end

    test "text, a number and text again, after the merge", %{branch: branch} do
      same_order_after_merge(branch, name: :asc, rank: :desc, name_icu: :asc)
    end
  end

  describe "with the whole name list" do
    test "text, a number and text again, after the merge", %{branch: branch} do
      seed!(branch)
      same_order_after_merge(branch, name: :asc, rank: :desc, name_icu: :asc)
    end

    test "a distinct keeps the first of each group in the collation's order", %{branch: branch} do
      seed!(branch, ["b", "B", "a", "A"], 2)

      picked =
        inside(branch, fn ->
          Tag
          |> Ash.Query.distinct([:kind])
          |> Ash.Query.sort(name_icu: :asc)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.name)
        end)

      # Every row has the same (nil) kind, so one row is kept: the first in ICU's order, where bytes would keep "A".
      assert picked == ["a"]
    end
  end

  describe "min, max, first and list" do
    setup %{branch: branch} do
      seed!(branch)
    end

    for {column, order} <- [name_c: :byte_order, name_icu: :icu_order] do
      test "#{column} min and max, with the delta and with a read of every row", %{branch: branch} do
        ordered = if unquote(order) == :byte_order, do: @byte_order, else: @icu_order
        column = unquote(column)

        inside(branch, fn ->
          for query <- [Tag, Ash.Query.limit(Tag, 100)] do
            assert Ramal.aggregate!(query, :min, column) == hd(ordered)
            assert Ramal.aggregate!(query, :max, column) == List.last(ordered)
          end
        end)
      end

      test "#{column} first and list follow the sort", %{branch: branch} do
        ordered = if unquote(order) == :byte_order, do: @byte_order, else: @icu_order
        column = unquote(column)

        inside(branch, fn ->
          asc = Ash.Query.sort(Tag, [{column, :asc}])
          assert Ramal.aggregate!(asc, :first, column) == hd(ordered)
          assert Ramal.aggregate!(asc, :list, column) == ordered

          desc = Ash.Query.sort(Tag, [{column, :desc}])
          assert Ramal.aggregate!(desc, :first, column) == List.last(ordered)
          assert Ramal.aggregate!(desc, :list, column) == Enum.reverse(ordered)
        end)
      end
    end

    for column <- [:name, :label] do
      test "#{column} equal the database's after the merge", %{branch: branch} do
        column = unquote(column)
        sort = [{column, :asc}, rank: :asc]
        every_row = Ash.Query.limit(Tag, 100)

        in_branch =
          inside(branch, fn ->
            %{
              min: text(Ramal.aggregate!(Tag, :min, column)),
              max: text(Ramal.aggregate!(Tag, :max, column)),
              min_of_every_row: text(Ramal.aggregate!(every_row, :min, column)),
              max_of_every_row: text(Ramal.aggregate!(every_row, :max, column)),
              first: text(Ramal.aggregate!(Ash.Query.sort(Tag, sort), :first, column)),
              list: Enum.map(Ramal.aggregate!(Ash.Query.sort(Tag, sort), :list, column), &text/1)
            }
          end)

        assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
        min = text(Ash.min!(Tag, column, authorize?: false))
        max = text(Ash.max!(Tag, column, authorize?: false))

        assert in_branch == %{
                 min: min,
                 max: max,
                 min_of_every_row: min,
                 max_of_every_row: max,
                 first: text(Ash.first!(Ash.Query.sort(Tag, sort), column, authorize?: false)),
                 list:
                   Enum.map(
                     Ash.list!(Ash.Query.sort(Tag, sort), column, authorize?: false),
                     &text/1
                   )
               }
      end
    end
  end

  describe "min and max combine the database's value with the branch's" do
    test "the branch's row can win under one collation and lose under another", %{branch: branch} do
      Ash.create!(Tag, attrs("Zebra", 100), authorize?: false)
      inside(branch, fn -> Ash.create!(Tag, attrs("apple", 101), authorize?: false) end)

      inside(branch, fn ->
        # In bytes "Zebra" < "apple"; in ICU "apple" < "Zebra".
        assert Ramal.aggregate!(Tag, :min, :name_c) == "Zebra"
        assert Ramal.aggregate!(Tag, :max, :name_c) == "apple"
        assert Ramal.aggregate!(Tag, :min, :name_icu) == "apple"
        assert Ramal.aggregate!(Tag, :max, :name_icu) == "Zebra"
      end)
    end
  end

  describe "aggregates declared on the resource" do
    setup %{branch: branch} do
      parent = Ash.create!(Tag, attrs("root", 100), authorize?: false)

      for {name, rank} <- Enum.with_index(@names) do
        create = fn ->
          Ash.create!(Tag, Map.put(attrs(name, rank), :parent_id, parent.id), authorize?: false)
        end

        if rank < 6, do: create.(), else: inside(branch, create)
      end

      {:ok, parent: parent}
    end

    defp load_parent(parent, load) do
      Tag
      |> Ash.Query.filter(id == ^parent.id)
      |> Ash.Query.load(load)
      |> Ash.read_one!(authorize?: false)
    end

    test "min, max, first and list of text", %{branch: branch, parent: parent} do
      load = [
        :min_child_name,
        :max_child_name,
        :min_child_name_c,
        :min_child_name_icu,
        :first_child_name,
        :child_names,
        :child_names_icu_desc
      ]

      loaded = inside(branch, fn -> load_parent(parent, load ++ [:max_child_label]) end)

      assert loaded.min_child_name_c == hd(@byte_order)
      assert loaded.min_child_name_icu == hd(@icu_order)
      assert loaded.child_names_icu_desc == Enum.reverse(@icu_order)

      assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
      database = load_parent(parent, load ++ [:max_child_label])

      assert Map.take(loaded, load) == Map.take(database, load)
      assert text(loaded.max_child_label) == text(database.max_child_label)
    end
  end

  describe "a sort through a relationship" do
    test "orders by the related column's collation", %{branch: branch} do
      parents =
        for {name, rank} <- Enum.with_index(@names),
            do: Ash.create!(Tag, attrs(name, rank), authorize?: false)

      for parent <- parents do
        inside(branch, fn ->
          Ash.create!(Tag, %{rank: 1000 + parent.rank, parent_id: parent.id}, authorize?: false)
        end)
      end

      # Renaming a parent in the branch is what makes the sort read the parents through the branch.
      inside(branch, fn ->
        Ash.update!(
          Enum.find(parents, &(&1.name == "ab")),
          %{name: "Zed", name_c: "Zed", name_icu: "Zed"},
          authorize?: false
        )
      end)

      in_branch = inside(branch, fn -> children_by_parent() end)

      # "Zed" follows "Zebra" in ICU's order.
      icu_parents = List.delete(@icu_order, "ab") ++ ["Zed"]
      assert Enum.map(in_branch.icu, &(&1 - 1000)) == Enum.map(icu_parents, &rank_of/1)

      assert {:ok, _result} = Ramal.merge(branch, authorize?: false)
      assert children_by_parent() == in_branch
    end
  end

  # The children, in the order of their parent's name in each of three collations. The first rows are the parents.
  defp children_by_parent do
    %{
      name: child_ranks(Ash.Sort.expr_sort(parent.name, :string)),
      c: child_ranks(Ash.Sort.expr_sort(parent.name_c, :string)),
      icu: child_ranks(Ash.Sort.expr_sort(parent.name_icu, :string))
    }
  end

  defp child_ranks(sort) do
    Tag
    |> Ash.Query.filter(not is_nil(parent_id))
    |> Ash.Query.sort([{sort, :asc}, rank: :asc])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.rank)
  end

  # The rank `seed!/1` gave a name, with "Zed" standing for the renamed "ab".
  defp rank_of("Zed"), do: rank_of("ab")
  defp rank_of(name), do: Enum.find_index(@names, &(&1 == name))

  describe "what is asked of the database" do
    test "one query ranks the distinct values of a text key", %{branch: branch} do
      seed!(branch)
      capture_queries()

      inside(branch, fn -> sorted(name_icu: :asc) end)

      assert [{sql, [values]}] = ranking_queries(all_queries())
      assert sql =~ ~s|COLLATE "pg_catalog"."und-x-icu"|
      assert Enum.sort(values) == Enum.sort(@names)
    end

    test "a column in byte order and a key that is not text ask nothing", %{branch: branch} do
      seed!(branch)
      capture_queries()

      inside(branch, fn ->
        sorted(name_c: :asc)
        sorted(rank: :desc)
      end)

      assert ranking_queries(all_queries()) == []
    end

    test "the collation of a column is read once", %{branch: branch} do
      seed!(branch)
      :persistent_term.erase({Collation, TestRepo, nil, "tags", "name"})
      capture_queries()

      inside(branch, fn ->
        sorted(name: :asc)
        sorted(name: :desc)
      end)

      queries = all_queries()
      assert length(Enum.filter(queries, fn {sql, _} -> sql =~ "pg_attribute" end)) == 1
      assert length(ranking_queries(queries)) == 2
    end

    test "a failing query is an error and not a wrong order", %{branch: branch} do
      seed!(branch)
      break_collation_of(:name_icu)

      assert {:error, error} =
               inside(branch, fn ->
                 Ash.read(Ash.Query.sort(Tag, name_icu: :asc), authorize?: false)
               end)

      assert %Ramal.Error{reason: :collation_failed} = Ramal.Error.find(error)
    end

    test "the minimum of text is an error when the query fails", %{branch: branch} do
      seed!(branch)
      break_collation_of(:name_icu)

      assert {:error, %Ramal.Error{reason: :collation_failed}} =
               inside(branch, fn -> Ramal.aggregate(Tag, :min, :name_icu) end)
    end
  end

  # ADR 0045 lists these as the gaps that remain, so the day one closes is visible here.
  describe "what still compares bytes" do
    setup %{branch: branch} do
      for {name, rank} <- Enum.with_index(["apple", "Banana", "cherry", "Date"]) do
        inside(branch, fn -> Ash.create!(Tag, attrs(name, rank), authorize?: false) end)
      end

      :ok
    end

    test "a comparison filter on text judges the branch's rows in bytes", %{branch: branch} do
      names =
        inside(branch, fn ->
          Tag
          |> Ash.Query.filter(name_icu > "Banana")
          |> Ash.Query.sort(name_icu: :asc)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.name_icu)
        end)

      # In ICU's order only "cherry" and "Date" follow "Banana"; the filter keeps "apple" too.
      assert names == ["apple", "cherry", "Date"]
    end

    test "a keyset cursor on a text sort compares bytes, so the page after it repeats a row", %{
      branch: branch
    } do
      names =
        inside(branch, fn ->
          sort = [name_icu: :asc, rank: :asc]

          first =
            Tag
            |> Ash.Query.for_read(:list)
            |> Ash.Query.sort(sort)
            |> Ash.read!(page: [limit: 2], authorize?: false)

          cursor = List.last(first.results)

          Tag
          |> Ash.Query.for_read(:list)
          |> Ash.Query.sort(sort)
          |> Ash.read!(page: [limit: 2, after: cursor.__metadata__.keyset], authorize?: false)
          |> Map.fetch!(:results)
          |> Enum.map(& &1.name_icu)
        end)

      # "Banana" ends the first page in ICU's order, so "cherry" and "Date" should follow.
      assert names == ["apple", "cherry"]
    end
  end

  describe "a resource with a schema for each tenant" do
    alias Ramal.Test.PgTenants
    alias Ramal.Test.PgTenants.Plot

    # The same column is `C` in one tenant's schema and the database's default in the other, so the collation cannot be
    # kept for the table.
    test "reads the collation of the tenant's own column" do
      for tenant <- ["org_a", "org_b"],
          do: AshPostgres.MultiTenancy.create_tenant!(tenant, TestRepo)

      TestRepo.query!(
        ~s|ALTER TABLE "org_b"."tenant_plots" ALTER COLUMN name TYPE text COLLATE "C"|
      )

      names = ["apple", "Banana", "cherry", "Date"]

      for {tenant, expected} <- [
            {"org_a", ["apple", "Banana", "cherry", "Date"]},
            {"org_b", ["Banana", "Date", "apple", "cherry"]}
          ] do
        {:ok, branch} = Ramal.branch(PgTenants, tenant: tenant)

        sorted =
          Ramal.run!(branch, fn ->
            for name <- names, do: Ash.create!(Plot, %{name: name}, tenant: tenant)

            Plot
            |> Ash.Query.sort(name: :asc)
            |> Ash.read!(tenant: tenant)
            |> Enum.map(& &1.name)
          end)

        # org_a is created with the default collation of the test database: en_US.UTF-8, like CI's.
        %{rows: [[apple_first?]]} = TestRepo.query!("SELECT 'apple'::text < 'Banana'::text")

        assert sorted ==
                 if(tenant == "org_a" and not apple_first?, do: Enum.sort(names), else: expected)
      end
    end
  end

  describe "another data layer" do
    test "keeps byte order", %{branch: branch} do
      labels = ["apple", "Banana", "cherry", "Date"]

      sorted =
        inside(branch, fn ->
          Enum.each(labels, &Ash.create!(Counter, %{label: &1}, authorize?: false))

          Counter
          |> Ash.Query.filter(label in ^labels)
          |> Ash.Query.sort(label: :asc)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.label)
        end)

      assert sorted == ["Banana", "Date", "apple", "cherry"]
    end
  end

  # Makes the collation of a column of `tags` come from a repo whose queries fail.
  defp break_collation_of(column) do
    key = {Collation, TestRepo, nil, "tags", to_string(column)}
    cached = :persistent_term.get(key, nil)
    :persistent_term.put(key, %{repo: Ramal.Test.BrokenRepo, collate: nil, lower?: false})

    on_exit(fn ->
      if cached, do: :persistent_term.put(key, cached), else: :persistent_term.erase(key)
    end)
  end

  # The repo's telemetry carries each query's SQL and parameters; they arrive as messages.
  defp capture_queries do
    test = self()
    handler = "collation-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ramal, :test_repo, :query],
      fn _event, _measurements, %{query: sql, params: params}, _config ->
        send(test, {:query, sql, params})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp all_queries(acc \\ []) do
    receive do
      {:query, sql, params} -> all_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ranking_queries(queries), do: Enum.filter(queries, fn {sql, _} -> sql =~ "dense_rank" end)
end
