import Config

# The test domain (test/support/farm) runs on a real Postgres: docker compose up -d db
# Tests that commit rows (test/ramal/preparation_async_test.exs, the "across a fresh VM" tests) and those that list a
# whole table see each other's rows when two runs share a database. MIX_TEST_PARTITION gives each run its own database
# (ramal_test1, ramal_test2, ...); `mix test` creates and migrates it through ash.setup.
# Override with RAMAL_PG_HOST / RAMAL_PG_PORT / RAMAL_PG_USER / RAMAL_PG_PASSWORD where docker is not available.
config :ramal, Ramal.TestRepo,
  username: System.get_env("RAMAL_PG_USER", "ramal"),
  password: System.get_env("RAMAL_PG_PASSWORD", "ramal"),
  hostname: System.get_env("RAMAL_PG_HOST", "localhost"),
  port: String.to_integer(System.get_env("RAMAL_PG_PORT", "5435")),
  database: "ramal_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ramal,
  ecto_repos: [Ramal.TestRepo],
  ash_domains: [Ramal.Test.Farm, Ramal.Test.PgTenants, Ramal.Test.Serial]

config :ash, :sat_solver, {SimpleSat, []}
config :ash, :missed_notifications, :ignore
# Required since Ash 3.37; codepoints is the value Ash recommends and matches how Postgres counts.
config :ash, default_string_length_count: :codepoints

config :logger, level: :warning
