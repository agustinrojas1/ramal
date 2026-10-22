defmodule Bench.Timing do
  @moduledoc false
  # A deliberately small harness: run a function a fixed number of times, after a few warm-up runs, and keep every
  # sample so that the JSON output can be re-analysed. Only the `run` function is timed; `setup` builds the state and
  # `teardown` receives that state and the result of `run` to clean up.

  @type stats :: %{
          runs: pos_integer,
          min_us: number,
          median_us: number,
          p95_us: number,
          mean_us: number,
          samples_us: [integer]
        }

  @spec measure(keyword) :: stats
  def measure(opts) do
    setup = Keyword.get(opts, :setup, fn -> nil end)
    run = Keyword.fetch!(opts, :run)
    teardown = Keyword.get(opts, :teardown, fn _state, _result -> :ok end)
    runs = Keyword.fetch!(opts, :runs)
    warmup = Keyword.get(opts, :warmup, 1)

    for _ <- 1..warmup//1, do: once(setup, run, teardown)
    samples = for _ <- 1..runs, do: once(setup, run, teardown)
    stats(samples)
  end

  defp once(setup, run, teardown) do
    state = setup.()
    :erlang.garbage_collect()
    {micros, result} = :timer.tc(fn -> run.(state) end)
    teardown.(state, result)
    micros
  end

  @spec stats([integer]) :: stats
  def stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)

    %{
      runs: n,
      min_us: hd(sorted),
      median_us: percentile(sorted, 50),
      p95_us: percentile(sorted, 95),
      mean_us: Enum.sum(sorted) / n,
      samples_us: samples
    }
  end

  # Nearest-rank percentile; with few samples p95 is the maximum, which is the honest reading.
  defp percentile(sorted, p) do
    rank = max(1, ceil(p / 100 * length(sorted)))
    Enum.at(sorted, rank - 1)
  end
end
