defmodule Bench do
  @moduledoc false
  # Runs every case, prints a table and writes the raw samples to bench/results/ as JSON.

  alias Bench.{Cases, Setup}

  @profiles %{
    full: %{
      rows: 20_000,
      buckets: 100,
      overlay_sizes: [0, 100, 1_000],
      other_overlay_sizes: [1_000, 10_000],
      runs: 30,
      warmup: 3,
      tree: %{depth: 3, branching: 4, keep: 2, mutate: 5}
    },
    quick: %{
      rows: 500,
      buckets: 10,
      overlay_sizes: [0, 10, 50],
      other_overlay_sizes: [50, 200],
      runs: 5,
      warmup: 1,
      tree: %{depth: 2, branching: 3, keep: 2, mutate: 3}
    }
  }

  @cases [
    :fork,
    :diff,
    :read,
    :read_other,
    :aggregate,
    :write,
    :merge,
    :fingerprint,
    :tree_search
  ]

  @spec run(:full | :quick, keyword) :: [map]
  def run(profile_name, opts \\ []) do
    profile = Map.fetch!(@profiles, profile_name)
    cases = Keyword.get(opts, :cases, @cases)

    env = Setup.run(profile.rows, profile.buckets) |> Map.put(:rows, profile.rows)
    {:ok, _} = Ramal.Supervisor.start_link([])
    Bench.Baseline.Copy.init()
    Bench.Baseline.Delta.init()

    results =
      Enum.flat_map(cases, fn name ->
        IO.puts("running #{name} ...")
        apply(Cases, name, [profile, env])
      end)

    print(results)

    unless opts[:no_json] do
      path = write_json(profile_name, profile, results)
      IO.puts("\nsamples written to #{path}")
    end

    results
  end

  def cases, do: @cases

  defp print(results) do
    IO.puts(
      "\n#{pad("case", 18)}#{pad("variant", 16)}#{pad("params", 66)}#{pad("median", 12)}#{pad("p95", 12)}min"
    )

    for r <- results do
      IO.puts(
        pad(r.case, 18) <>
          pad(r.variant, 16) <>
          pad(params(r.params), 66) <>
          pad(ms(r.stats.median_us), 12) <> pad(ms(r.stats.p95_us), 12) <> ms(r.stats.min_us)
      )
    end
  end

  defp params(map), do: map |> Enum.sort() |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{v}" end)
  defp ms(us), do: "#{:erlang.float_to_binary(us / 1_000, decimals: 2)} ms"
  defp pad(value, width), do: String.pad_trailing(to_string(value), width)

  defp write_json(profile_name, profile, results) do
    File.mkdir_p!("results")
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    path = Path.join("results", "#{profile_name}-#{stamp}.json")

    payload = %{
      profile: profile_name,
      settings: profile,
      machine: machine(),
      results: results
    }

    File.write!(path, Jason.encode!(payload, pretty: true))
    path
  end

  defp machine do
    %{
      cpu: cpu(),
      logical_cores: System.schedulers_online(),
      memory_kb: memory_kb(),
      os: to_string(:erlang.system_info(:system_architecture)),
      erlang: to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      postgres: Setup.postgres_version(),
      ramal: version(:ramal),
      ash: version(:ash),
      ash_postgres: version(:ash_postgres)
    }
  end

  defp version(app), do: app |> Application.spec(:vsn) |> to_string()

  defp cpu do
    with {:ok, text} <- File.read("/proc/cpuinfo"),
         [_, name] <- Regex.run(~r/model name\s*:\s*(.+)/, text) do
      name
    else
      _ -> "unknown"
    end
  end

  defp memory_kb do
    with {:ok, text} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/MemTotal:\s*(\d+)/, text) do
      String.to_integer(kb)
    else
      _ -> nil
    end
  end
end
