defmodule Bench.Hibernation do
  @moduledoc false
  # Measures the memory and wake cost of an idle branch process, for issue #274.
  # For each overlay size it reports, in bytes/words:
  #   * idle      - process memory right after the write, no compaction
  #   * gc        - after :erlang.garbage_collect/1
  #   * hibernate - after Ramal.Branch.Server.hibernate_now/1
  #   * reload    - after unloading and loading again (current idle behavior)
  # and the wake latency (microseconds) of the first call after each state.

  alias Bench.Row
  alias Ecto.Adapters.SQL
  alias Ramal.Branch.Server

  @sizes [0, 100, 1_000, 5_000]

  def run(opts \\ []) do
    sizes = Keyword.get(opts, :sizes, @sizes)
    config = Bench.Repo.config()
    _ = Bench.Repo.__adapter__().storage_up(config)
    {:ok, _} = Bench.Repo.start_link()
    {:ok, _} = Ramal.Supervisor.start_link(idle_timeout: :infinity)

    seed(Enum.max(sizes))

    results = Enum.map(sizes, &measure/1)
    print(results)
    results
  end

  defp seed(count) when count > 0 do
    SQL.query!(Bench.Repo, "DROP TABLE IF EXISTS bench_rows", [])

    SQL.query!(Bench.Repo, """
    CREATE TABLE bench_rows (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      notes text,
      score integer NOT NULL,
      parent_id uuid,
      inserted_at timestamp NOT NULL,
      updated_at timestamp NOT NULL
    )
    """, [])

    SQL.query!(Bench.Repo, """
    INSERT INTO bench_rows (id, name, notes, score, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'row-' || i, 'note ' || i, i % 1000, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc'
    FROM generate_series(1, $1) AS i
    """, [count])

    Row |> Ash.Query.sort(:name) |> Ash.read!()
  end

  defp seed(0), do: seed(1)

  defp measure(size) do
    {:ok, branch} = write(size)
    pid = Ramal.Supervisor.whereis(branch.id)

    idle_mem = process_memory(pid)
    idle_heap = total_heap_size(pid)

    :erlang.garbage_collect(pid)
    gc_mem = process_memory(pid)
    gc_heap = total_heap_size(pid)
    gc_wake = wake_latency(branch.id)

    Server.hibernate_now(branch.id)
    hib_mem = process_memory(pid)
    hib_heap = total_heap_size(pid)
    hib_wake = wake_latency(branch.id)

    GenServer.stop(pid, :shutdown)
    {:ok, _} = Server.status(branch.id)
    reloaded_pid = Ramal.Supervisor.whereis(branch.id)
    reload_mem = process_memory(reloaded_pid)
    reload_heap = total_heap_size(reloaded_pid)
    reload_wake = wake_latency(branch.id)

    %{
      rows: size,
      idle_memory_bytes: idle_mem,
      idle_heap_words: idle_heap,
      gc_memory_bytes: gc_mem,
      gc_heap_words: gc_heap,
      gc_wake_us: gc_wake,
      hibernate_memory_bytes: hib_mem,
      hibernate_heap_words: hib_heap,
      hibernate_wake_us: hib_wake,
      reload_memory_bytes: reload_mem,
      reload_heap_words: reload_heap,
      reload_wake_us: reload_wake
    }
  end

  defp write(0) do
    {:ok, branch} = Ramal.branch(Bench.Domain)
    {:ok, branch}
  end

  defp write(size) do
    {:ok, branch} = Ramal.branch(Bench.Domain)
    rows = Row |> Ash.Query.sort(:name) |> Ash.Query.limit(size) |> Ash.read!()

    Ramal.run!(branch.id, fn ->
      Enum.each(rows, &Ash.update!(&1, %{score: &1.score + 1}))
    end)

    {:ok, branch}
  end

  defp process_memory(pid), do: (Process.info(pid, :memory) |> elem(1))
  defp total_heap_size(pid), do: (Process.info(pid, :total_heap_size) |> elem(1))

  defp wake_latency(id) do
    t0 = System.monotonic_time(:microsecond)
    _ = Server.status(id)
    System.monotonic_time(:microsecond) - t0
  end

  defp print(results) do
    IO.puts("\nHibernation evaluation (issue #274)\n")

    header =
      pad("rows", 8) <>
        pad("idle B", 12) <> pad("idle words", 12) <>
        pad("gc B", 12) <> pad("gc words", 12) <> pad("gc wake us", 12) <>
        pad("hib B", 12) <> pad("hib words", 12) <> pad("hib wake us", 12) <>
        pad("reload B", 12) <> pad("reload words", 12) <> "reload wake us"

    IO.puts(header)

    for r <- results do
      IO.puts(
        pad(r.rows, 8) <>
          pad(r.idle_memory_bytes, 12) <> pad(r.idle_heap_words, 12) <>
          pad(r.gc_memory_bytes, 12) <> pad(r.gc_heap_words, 12) <> pad(r.gc_wake_us, 12) <>
          pad(r.hibernate_memory_bytes, 12) <> pad(r.hibernate_heap_words, 12) <> pad(r.hibernate_wake_us, 12) <>
          pad(r.reload_memory_bytes, 12) <> pad(r.reload_heap_words, 12) <> to_string(r.reload_wake_us)
      )
    end
  end

  defp pad(value, width), do: String.pad_trailing(to_string(value), width)
end