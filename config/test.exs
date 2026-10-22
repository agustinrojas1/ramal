import Config

# The test domain (test/support/farm) runs on a real Postgres: docker compose up -d db
# Override with RAMAL_PG_HOST / RAMAL_PG_PORT / RAMAL_PG_USER / RAMAL_PG_PASSWORD where docker is not available.
config :ramal, Ramal.TestRepo,
  username: System.get_env("RAMAL_PG_USER", "ramal"),
  password: System.get_env("RAMAL_PG_PASSWORD", "ramal"),
  hostname: System.get_env("RAMAL_PG_HOST", "localhost"),
  port: String.to_integer(System.get_env("RAMAL_PG_PORT", "5435")),
  database: "ramal_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ramal,
  ecto_repos: [Ramal.TestRepo],
  ash_domains: [Ramal.Test.Farm]

config :ash, :sat_solver, {SimpleSat, []}
config :ash, :missed_notifications, :ignore
# Required since Ash 3.37; codepoints is the value Ash recommends and matches how Postgres counts.
config :ash, default_string_length_count: :codepoints

config :logger, level: :warning
