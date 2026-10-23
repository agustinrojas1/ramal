defmodule Bench.Cases do
  @moduledoc false
  # The measured cases. Each returns a list of result maps:
  #
  #   %{case: atom, variant: atom, params: map, stats: Bench.Timing.stats}
  #
  # Every variant of a case does the same logical work on the same data. State is built outside the timed function.

  alias Bench.{RamalSide, Timing}
  alias Bench.Baseline.{Copy, Delta}

  @base_table "bench_items"

  # Variants as a map of functions over an opaque node: the node is a branch for Ramal, a table for the copy baseline
  # and a state number for the delta baseline.
  def variants do
    %{
      ramal: %{
        root: &RamalSide.branch/0,
        scratch: &RamalSide.branch/0,
        fork: &RamalSide.fork/1,
        update: &RamalSide.update/3,
        read: &RamalSide.read/2,
        sum: &RamalSide.sum/1,
        discard: &RamalSide.discard/1
      },
      delta: %{
        root: fn -> 0 end,
        scratch: &Delta.new_state/0,
        fork: &Delta.fork/1,
        update: &Delta.update/3,
        read: &Delta.read/2,
        sum: &Delta.sum/1,
        discard: &Delta.discard/1
      },
      copy: %{
        root: fn -> @base_table end,
        scratch: fn -> Copy.fork(@base_table) end,
        fork: &Copy.fork/1,
        update: &Copy.update/3,
        read: &Copy.read/2,
        sum: &Copy.sum/1,
        discard: fn
          @base_table -> :ok
          table -> Copy.discard(table)
        end
      }
    }
  end

  # A node whose overlay holds `size` updated rows. The score written is a function of the row, so every variant holds
  # the same logical state. It starts from `scratch`, not `root`: the root of the copy variant is the base table itself,
  # and writing into that would change the base for every case that runs after this one.
  defp loaded(variant, ids, size) do
    node = variant.scratch.()

    ids
    |> Enum.take(size)
    |> Enum.with_index()
    |> Enum.each(fn {id, i} -> variant.update.(node, id, 2_000 + i) end)

    node
  end

  def fork(profile, env) do
    for size <- profile.overlay_sizes, {name, variant} <- variants() do
      parent = loaded(variant, env.ids, size)

      stats =
        Timing.measure(
          run: fn _ -> variant.fork.(parent) end,
          teardown: fn _, forked -> variant.discard.(forked) end,
          runs: profile.runs,
          warmup: profile.warmup
        )

      variant.discard.(parent)
      result(:fork, name, %{overlay: size, rows: env.rows}, stats)
    end
  end

  # The changes of a node whose overlay holds `size` updated rows. Only Ramal computes a diff (the baselines have no
  # equivalent that needs no query), so there is no comparison variant. Raises when the diff is not one change per row.
  def diff(profile, env) do
    ramal = variants().ramal

    for size <- profile.overlay_sizes, size > 0 do
      node = loaded(ramal, env.ids, size)

      stats =
        Timing.measure(
          run: fn _ ->
            changes = RamalSide.diff(node)

            if length(changes) != size,
              do: raise("diff found #{length(changes)} changes for #{size} updates")
          end,
          runs: profile.runs,
          warmup: profile.warmup
        )

      ramal.discard.(node)
      result(:diff, :ramal, %{overlay: size}, stats)
    end
  end

  # A read of `Bench.Note`, which the branch never touched, in a node whose overlay holds `size` updated `Bench.Item`
  # rows. The read asks the branch process what it holds for the resource, so this is the price of the other resource's
  # overlay. Only Ramal has the case; `ash_no_branch` is the same read with no branch.
  def read_other(profile, env) do
    ramal = variants().ramal

    for size <- profile.other_overlay_sizes do
      node = loaded(ramal, env.ids, size)
      stats = measure_read(profile, fn -> RamalSide.read_note(node) end)
      ramal.discard.(node)
      result(:read_other, :ramal, %{overlay: size}, stats)
    end ++
      [
        result(
          :read_other,
          :ash_no_branch,
          %{overlay: 0},
          measure_read(profile, fn -> RamalSide.read_note_base() end)
        )
      ]
  end

  # The sum of `score` over the whole table in a node with that overlay: what `Ramal.aggregate!/4` costs next to the
  # same sum in the baselines and with no branch at all.
  def aggregate(profile, env) do
    for size <- profile.overlay_sizes, {name, variant} <- variants() do
      node = loaded(variant, env.ids, size)
      stats = measure_read(profile, fn -> variant.sum.(node) end)
      variant.discard.(node)
      result(:aggregate, name, %{overlay: size}, stats)
    end ++
      [
        result(
          :aggregate,
          :ash_no_branch,
          %{overlay: 0},
          measure_read(profile, fn -> RamalSide.sum_base() end)
        )
      ]
  end

  def read(profile, env) do
    bounds = [small: 1, wide: max(2, div(env.buckets, 10))]

    for size <- profile.overlay_sizes,
        {shape, bound} <- bounds,
        {name, variant} <- variants() do
      node = loaded(variant, env.ids, size)
      stats = measure_read(profile, fn -> variant.read.(node, bound) end)
      variant.discard.(node)
      result(:read, name, %{overlay: size, shape: shape, bucket_bound: bound}, stats)
    end ++ read_references(profile, bounds)
  end

  # What the same read costs through Ash with no branch at all: the floor Ramal adds to.
  defp read_references(profile, bounds) do
    for {shape, bound} <- bounds do
      stats = measure_read(profile, fn -> RamalSide.read_base(bound) end)
      result(:read, :ash_no_branch, %{overlay: 0, shape: shape, bucket_bound: bound}, stats)
    end
  end

  defp measure_read(profile, fun) do
    Timing.measure(run: fn _ -> fun.() end, runs: profile.runs, warmup: profile.warmup)
  end

  def write(profile, env) do
    for size <- profile.overlay_sizes, {name, variant} <- variants() do
      node = loaded(variant, env.ids, size)
      id = Enum.at(env.ids, size)
      counter = :counters.new(1, [])

      stats =
        Timing.measure(
          run: fn _ ->
            :counters.add(counter, 1, 1)
            variant.update.(node, id, :counters.get(counter, 1))
          end,
          runs: profile.runs,
          warmup: profile.warmup
        )

      variant.discard.(node)
      result(:write, name, %{overlay: size}, stats)
    end ++ [write_reference(profile, env)]
  end

  # One update written to the base inside a transaction that is rolled back: what a write costs with no branching.
  defp write_reference(profile, env) do
    id = Enum.at(env.ids, 0)

    stats =
      Timing.measure(
        run: fn _ ->
          Bench.Repo.transaction(fn ->
            Bench.Item |> Ash.get!(id) |> Ash.update!(%{score: 1})
            Bench.Repo.rollback(:measured)
          end)
        end,
        runs: profile.runs,
        warmup: profile.warmup
      )

    result(:write, :ash_base_write, %{overlay: 0}, stats)
  end

  # Merge of `size` updated rows. Ramal replays each through the real update action; the baseline applies the delta in
  # one SQL statement. The baseline is expected to win by a wide margin, and the number is the price of replaying
  # through actions, which is what buys validations, policies and a staleness check.
  def merge(profile, env) do
    for size <- profile.overlay_sizes, size > 0 do
      [
        merge_variant(
          profile,
          env,
          size,
          :ramal,
          &RamalSide.branch/0,
          &RamalSide.update/3,
          &RamalSide.merge/1
        ),
        merge_variant(
          profile,
          env,
          size,
          :delta,
          fn -> Delta.new_state() end,
          &Delta.update/3,
          &Delta.merge/1
        )
      ]
    end
    |> List.flatten()
  end

  defp merge_variant(profile, env, size, name, root, update, merge) do
    run_index = :counters.new(1, [])

    stats =
      Timing.measure(
        setup: fn ->
          :counters.add(run_index, 1, 1)
          offset = :counters.get(run_index, 1) * 10_000
          node = root.()

          env.ids
          |> Enum.take(size)
          |> Enum.with_index()
          |> Enum.each(fn {id, i} -> update.(node, id, offset + i) end)

          node
        end,
        run: merge,
        runs: profile.runs,
        warmup: profile.warmup
      )

    result(:merge, name, %{overlay: size}, stats)
  end

  # Ramal.Resource.fingerprint over R in-memory records, and the read overhead of an empty branch (which fingerprints
  # every base row it returns) against the same read with no branch.
  def fingerprint(profile, env) do
    records = Bench.Item |> Ash.read!() |> Enum.take(env.rows)

    direct =
      for count <- Enum.uniq([min(100, env.rows), min(1_000, env.rows), env.rows]) do
        slice = Enum.take(records, count)

        stats =
          Timing.measure(
            run: fn _ -> Enum.each(slice, &Ramal.Resource.fingerprint/1) end,
            runs: profile.runs,
            warmup: profile.warmup
          )

        result(:fingerprint, :ramal, %{records: count}, stats)
      end

    bound = max(2, div(env.buckets, 10))
    empty = RamalSide.branch()

    overhead = [
      result(
        :empty_branch_read,
        :ash_no_branch,
        %{bucket_bound: bound},
        measure_read(profile, fn -> RamalSide.read_base(bound) end)
      ),
      result(
        :empty_branch_read,
        :ramal,
        %{bucket_bound: bound},
        measure_read(profile, fn -> RamalSide.read(empty, bound) end)
      )
    ]

    RamalSide.discard(empty)
    direct ++ overhead
  end

  # A search over alternate states: from the root, each level forks `branching` children from every kept node, changes
  # `mutate` rows in each, scores it and keeps the best `keep`. Mutations are a pure function of the position in the
  # tree, so every variant does the same logical work and must find the same best score; a difference is a bug.
  def tree_search(profile, env) do
    params = profile.tree

    {results, _expected} =
      Enum.map_reduce(variants(), nil, fn {name, variant}, expected ->
        warmups = for _ <- 1..profile.warmup//1, do: search(variant, env, params)
        timed = for _ <- 1..profile.runs, do: :timer.tc(fn -> search(variant, env, params) end)

        best = timed |> Enum.map(&elem(&1, 1)) |> Kernel.++(warmups) |> Enum.uniq() |> one!(name)

        if expected && expected != best,
          do: raise("variant #{name} found #{best}, expected #{expected}")

        stats = timed |> Enum.map(&elem(&1, 0)) |> Timing.stats()
        {result(:tree_search, name, Map.put(params, :best_score, best), stats), expected || best}
      end)

    results
  end

  defp one!([best], _name), do: best
  defp one!(other, name), do: raise("variant #{name} was not deterministic: #{inspect(other)}")

  defp search(variant, env, %{depth: depth, branching: branching, keep: keep, mutate: mutate}) do
    root = variant.root.()

    survivors =
      Enum.reduce(1..depth, [{root, "r"}], fn level, frontier ->
        children =
          for {parent, path} <- frontier, child <- 1..branching do
            node = variant.fork.(parent)
            child_path = "#{path}.#{child}"

            for j <- 1..mutate do
              index = :erlang.phash2({level, child_path, j}, env.rows)
              score = :erlang.phash2({:score, level, child_path, j}, 1_000)
              variant.update.(node, Enum.at(env.ids, index), score)
            end

            {node, child_path, variant.sum.(node)}
          end

        # ties break on the path so that every variant keeps the same nodes
        {kept, dropped} =
          children
          |> Enum.sort_by(fn {_node, path, score} -> {-score, path} end)
          |> Enum.split(keep)

        Enum.each(dropped, fn {node, _, _} -> variant.discard.(node) end)
        if level > 1, do: Enum.each(frontier, fn {node, _} -> variant.discard.(node) end)
        Enum.map(kept, fn {node, path, _score} -> {node, path} end)
      end)

    best = survivors |> Enum.map(fn {node, _} -> variant.sum.(node) end) |> Enum.max()
    Enum.each(survivors, fn {node, _} -> variant.discard.(node) end)
    variant.discard.(root)
    best
  end

  defp result(case_name, variant, params, stats) do
    %{case: case_name, variant: variant, params: params, stats: stats}
  end
end
