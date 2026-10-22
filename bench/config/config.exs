import Config

# docker compose up -d db (from the repository root) gives a Postgres on 5435; BENCH_PG_* override it.
config :bench, Bench.Repo,
  username: System.get_env("BENCH_PG_USER", "ramal"),
  password: System.get_env("BENCH_PG_PASSWORD", "ramal"),
  hostname: System.get_env("BENCH_PG_HOST", "localhost"),
  port: String.to_integer(System.get_env("BENCH_PG_PORT", "5435")),
  database: System.get_env("BENCH_PG_DATABASE", "ramal_bench"),
  pool_size: 10,
  log: false

config :bench, ecto_repos: [Bench.Repo], ash_domains: [Bench.Domain]

config :ash, :sat_solver, {SimpleSat, []}
config :ash, :missed_notifications, :ignore
config :ash, default_string_length_count: :codepoints
config :logger, level: :warning
