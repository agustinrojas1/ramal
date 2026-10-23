defmodule Bench.Memory do
  @moduledoc false
  # What a branch costs in memory, by what it holds. `mix bench.memory` fills a branch with updated and created rows and
  # prints, for each size, the three places a branch lives in:
  #
  #   * the heap of its process, in words: `:erts_debug.size/1` of what the process holds, which counts a term shared
  #     by many rows once, as the heap does (a copy made by a message or by ETS counts it every time);
  #   * the ETS table of `Ramal.Storage.ETS`, in words, where an idle branch waits (`:ets.info(table, :memory)`);
  #   * the JSON that `Ramal.Storage.Postgres` stores, in bytes.
  #
  # Rows are read first and then updated inside the branch, which is what a host does: the branch keeps the row as the
  # database gave it (the snapshot) and the row as the update left it.

  alias Bench.Row
  alias Ecto.Adapters.SQL
  alias Ramal.Branch.Server

  @sizes [100, 1_000, 5_000]
  @created 200

  def run(opts \\ []) do
    sizes = Keyword.get(opts, :sizes, @sizes)
    config = Bench.Repo.config()
    _ = Bench.Repo.__adapter__().storage_up(config)
    {:ok, _} = Bench.Repo.start_link()
    {:ok, _} = Ramal.Supervisor.start_link([])

    seed(Enum.max(sizes))

    results = Enum.map(sizes, &measure/1)
    print(results)
    results
  end

  defp seed(count) do
    SQL.query!(Bench.Repo, "DROP TABLE IF EXISTS bench_rows", [])

    SQL.query!(
      Bench.Repo,
      """
      CREATE TABLE bench_rows (
        id uuid PRIMARY KEY,
        name text NOT NULL,
        notes text,
        score integer NOT NULL,
        parent_id uuid,
        inserted_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
      )
      """,
      []
    )

    SQL.query!(
      Bench.Repo,
      """
      INSERT INTO bench_rows (id, name, notes, score, inserted_at, updated_at)
      SELECT gen_random_uuid(), 'row-' || i, 'note ' || i, i % 1000, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
      FROM generate_series(1, $1) AS i
      """,
      [count]
    )

    Row |> Ash.Query.sort(:name) |> Ash.read!()
  end

  defp measure(size) do
    {:ok, branch} = write(size)

    pid = Ramal.Supervisor.whereis(branch.id)
    held = heap_words(branch.id)
    {:ok, current} = Server.get(branch.id)

    :ok = Ramal.Storage.ETS.put(current, [])
    ets = :ets.info(Ramal.Storage.ETS, :memory)
    :ok = Ramal.Storage.ETS.delete(branch.id, [])

    {:ok, state} = Ramal.Storage.Codec.encode_state(current)
    json = state |> Jason.encode!() |> byte_size()

    # Unload and load again: the process that loads the branch starts from a copy that kept no sharing.
    GenServer.stop(pid, :shutdown)
    {:ok, _} = Server.status(branch.id)
    reloaded = heap_words(branch.id)

    merge_words = merge_heap_words(branch.id)

    %{
      rows_updated: size,
      rows_created: @created,
      heap_words: held,
      heap_words_after_reload: reloaded,
      ets_words: ets,
      json_bytes: json,
      merge_heap_words: merge_words
    }
  end

  # The rows are read again for each branch, because a merge changes them in the database.
  defp write(size) do
    {:ok, branch} = Ramal.branch(Bench.Domain)
    rows = Row |> Ash.Query.sort(:name) |> Ash.Query.limit(size) |> Ash.read!()

    Ramal.run!(branch.id, fn ->
      Enum.each(rows, &Ash.update!(&1, %{score: &1.score + 1}))
      for i <- 1..@created, do: Ash.create!(Row, %{name: "new-#{i}", score: i, notes: "created"})
    end)

    {:ok, branch}
  end

  # The largest heap, in words, that the process calling `Ramal.merge/1` had at the end of one of its garbage
  # collections (`heap_block_size` and `old_heap_block_size` of the trace event), which is what holds the copies of the
  # branch that the merge makes in the caller. The result of the merge is kept alive until the end.
  defp merge_heap_words(id) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = Ramal.merge(id)
        send(parent, {:merged, self(), result})
        receive do: (:done -> :ok)
      end)

    :erlang.trace(pid, true, [:garbage_collection, {:tracer, self()}])

    receive do
      {:merged, ^pid, {:ok, _result}} -> :ok
      {:DOWN, ^ref, _, _, reason} -> raise "merge process died: #{inspect(reason)}"
    end

    send(pid, :done)
    collect_gc(pid, 0)
  end

  defp collect_gc(pid, peak) do
    receive do
      {:trace, ^pid, event, info} when event in [:gc_minor_end, :gc_major_end] ->
        blocks =
          Keyword.get(info, :heap_block_size, 0) + Keyword.get(info, :old_heap_block_size, 0)

        collect_gc(pid, max(peak, blocks))

      {:trace, ^pid, _event, _info} ->
        collect_gc(pid, peak)

      {:DOWN, _ref, :process, ^pid, _reason} ->
        peak
    after
      200 -> peak
    end
  end

  # Measured inside the process: a copy made to ask the question would not have the sharing of the process's heap.
  defp heap_words(id) do
    # `:erts_debug.size/1` takes seconds for a large branch, longer than the default call timeout.
    fun = fn branch -> {:erts_debug.size({branch.overlay, branch.base, branch.log}), branch} end
    {:ok, words, _} = GenServer.call(Ramal.Supervisor.whereis(id), {:write, fun}, :infinity)
    words
  end

  defp print(results) do
    IO.puts("\nMemory of a branch (Bench.Row: 7 attributes, 2 relationships, 1 aggregate)\n")

    IO.puts(
      pad("rows updated", 14) <>
        pad("created", 10) <>
        pad("heap words", 14) <>
        pad("after reload", 14) <>
        pad("ETS words", 14) <> pad("stored JSON bytes", 20) <> "merge heap words"
    )

    for r <- results do
      IO.puts(
        pad(r.rows_updated, 14) <>
          pad(r.rows_created, 10) <>
          pad(r.heap_words, 14) <>
          pad(r.heap_words_after_reload, 14) <>
          pad(r.ets_words, 14) <> pad(r.json_bytes, 20) <> to_string(r.merge_heap_words)
      )
    end
  end

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)
end
